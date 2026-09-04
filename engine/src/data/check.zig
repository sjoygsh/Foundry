//! Checking a parsed document against the schemas it claims to instantiate.
//!
//! The step between the parser and the package writer. The parser answered "is this a
//! `.fdt` file?"; this answers "is this content?" — the schema a record names exists,
//! every field it writes is one that schema declares, every value fits the declared type,
//! and every field the schema requires is present.
//!
//! What comes out is laid out **by schema field index** rather than by name, which is the
//! shape §5's binary format writes and §8's store reads. The name-to-index lookup happens
//! once per record here, and never again.
//!
//! **Defaults are filled here**, at every level. That is what makes "absent" in a checked
//! record mean exactly one thing — the author left an *optional* field out — so nothing
//! downstream has to know a schema's defaults in order to read a record correctly.
//!
//! Untrusted input, so every refusal is a diagnostic naming a place, never an assertion,
//! and the pass keeps going: a package with thirty mistakes reports thirty.
//!
//! See `docs/design/content-schemas.md` §3 and §6.

const std = @import("std");
const core = @import("core");

const diagnostic = @import("diagnostic.zig");
const id_mod = @import("id.zig");
const limits_mod = @import("limits.zig");
const parser_mod = @import("parser.zig");
const schema_mod = @import("schema.zig");
const value_mod = @import("value.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Diagnostics = diagnostic.Diagnostics;
const Document = parser_mod.Document;
const Field = schema_mod.Field;
const FieldType = schema_mod.FieldType;
const Limits = limits_mod.Limits;
const NamedValue = value_mod.NamedValue;
const Origin = parser_mod.Origin;
const RecordDecl = parser_mod.RecordDecl;
const Registry = schema_mod.Registry;
const Schema = schema_mod.Schema;
const SchemaHandle = schema_mod.SchemaHandle;
const SchemaId = id_mod.SchemaId;
const Value = value_mod.Value;

pub const Error = error{
    /// At least one diagnostic of severity `error` was recorded. The diagnostics are the
    /// result; this is only the signal.
    ContentInvalid,
} || Allocator.Error;

/// One record, checked, with its fields in schema order.
pub const Record = struct {
    /// Resolved once, here, and held as a handle from then on — the mitigation ADR-0005
    /// named for handle indirection, spent where §8 says to spend it.
    schema: SchemaHandle,
    schema_id: SchemaId,
    id: ContentId,
    /// The source spelling of `id`. Kept because every question anyone asks of a merged
    /// content set — which package won, why is this heavy — is asked using the name, and
    /// a `u64` cannot answer it.
    text: []const u8,
    /// One entry per field the schema had **when this record was checked**, in schema
    /// field order. `null` means absent, which only an `optional` field can be: a
    /// required field would have been refused and a defaulted one carries its default.
    values: []const ?Value,
    origin: Origin,

    /// The value of field `index`, or null if it is absent.
    ///
    /// Takes the schema because a schema can be *extended* after a record is checked
    /// (§3): a field appended by a later version is not in `values` at all, and its
    /// declared default is the right answer for content written before it existed. That
    /// is the whole reason extension is required to be additive.
    pub fn value(self: Record, schema: Schema, index: u32) ?Value {
        if (index < self.values.len) return self.values[index];
        if (index >= schema.fields.len) return null;
        return switch (schema.fields[index].presence) {
            .default => |d| d,
            else => null,
        };
    }
};

/// The checked records of one package, in authoring order.
///
/// Not to be confused with a loaded `.fpk`: this is the *compiler's* representation —
/// a tree of tagged unions, which §5.3 is explicit about not being what the engine reads
/// at runtime. `fpack` builds one of these and writes it out; the engine reads what was
/// written.
///
/// The order of `records` is the second of the two iteration orders §6 pins down, and I9
/// depends on it: the order the records appeared in the authoring text, with imports
/// inlined at their point of use. Appending is the only way in, so it is preserved by
/// construction rather than by care.
pub const Package = struct {
    arena: core.Arena,
    /// The package's own content id — `foundry:core` for package zero (I3). A package is
    /// content like anything else, which is what lets load order, overrides and, later, a
    /// mod manifest all address it the same way everything else is addressed.
    id: ContentId,
    /// The source spelling of `id`.
    name: []const u8,
    version: u32,
    limits: Limits,
    list: std.ArrayList(Record) = .empty,
    by_id: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// Every schema this package needs: the ones it declares, in declaration order,
    /// then the ones its records merely use, in order of first use. Each appears once.
    ///
    /// **Used, not only declared**, because a package's records are laid out against a
    /// schema *at a version*, and a package that did not carry that version could not say
    /// which one its bytes are shaped like. A mod adding `foundry:item` records therefore
    /// ships a copy of `foundry:item` as it was when the mod was compiled — which is
    /// exactly what makes the mod survive the base game extending that schema later (§3),
    /// and what lets a `.fpk` be read with nothing but itself.
    schemas: std.ArrayList(SchemaRef) = .empty,

    /// A schema id and the spelling it was written with. The registry holds only the
    /// hash, and a compiled package has to carry the name: "unknown schema 4f2a…" is not
    /// a thing anyone can act on.
    pub const SchemaRef = struct {
        id: SchemaId,
        text: []const u8,
    };

    /// Records that this package carries `schema_id`, spelled `text`, if it does not
    /// already. Called for every declaration and for every record's schema.
    fn noteSchema(self: *Package, gpa: Allocator, schema_id: SchemaId, text: []const u8) Allocator.Error!void {
        for (self.schemas.items) |seen| {
            if (seen.id.eql(schema_id)) return;
        }
        try self.schemas.append(gpa, .{
            .id = schema_id,
            .text = try self.arena.allocator().dupe(u8, text),
        });
    }

    pub const InitError = id_mod.Error || Allocator.Error;

    /// `name` is the package's `namespace:name`, validated here — a package with an
    /// unspellable id could not be depended on, overridden or reported.
    pub fn init(gpa: Allocator, name: []const u8, version: u32, limits: Limits) InitError!Package {
        const package_id = try id_mod.contentId(name);
        var pkg: Package = .{
            .arena = .init(gpa),
            .id = package_id,
            .name = "",
            .version = version,
            .limits = limits,
        };
        errdefer pkg.arena.deinit();
        pkg.name = try pkg.arena.allocator().dupe(u8, name);
        return pkg;
    }

    pub fn deinit(self: *Package, gpa: Allocator) void {
        self.list.deinit(gpa);
        self.by_id.deinit(gpa);
        self.schemas.deinit(gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// The part of `name` before the colon.
    pub fn namespace(self: *const Package) []const u8 {
        const colon = std.mem.indexOfScalar(u8, self.name, ':') orelse return self.name;
        return self.name[0..colon];
    }

    pub fn count(self: *const Package) u32 {
        return @intCast(self.list.items.len);
    }

    pub fn records(self: *const Package) []const Record {
        return self.list.items;
    }

    /// The position of a record in `records()`, which is also its merge order.
    pub fn find(self: *const Package, id: ContentId) ?u32 {
        return self.by_id.get(id.hash);
    }

    pub fn lookup(self: *const Package, id: ContentId) ?Record {
        return self.list.items[self.find(id) orelse return null];
    }

    /// Registers a document's `@schema` declarations into `registry`, and records that
    /// this package declares them.
    ///
    /// A schema the registry refuses is reported against the `@schema` that declared it
    /// and then skipped. Records naming it will fail too, which is the right outcome and
    /// is worth one extra message: "unknown schema" after "schema was refused" tells a
    /// truer story than silence about the records would.
    pub fn registerSchemas(
        self: *Package,
        gpa: Allocator,
        doc: *const Document,
        registry: *Registry,
        diags: *Diagnostics,
    ) Error!void {
        var failed = false;
        for (doc.schemas) |decl| {
            _ = registry.register(gpa, .{
                .id = decl.id,
                .version = decl.version,
                .fields = decl.fields,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    failed = true;
                    try diags.addFmt(
                        gpa,
                        .err,
                        decl.origin.location(),
                        decl.origin.length,
                        decl.origin.line_text,
                        "schema '{s}' {s}",
                        .{ decl.text, schema_mod.describeRegisterError(err) },
                    );
                    continue;
                },
            };
            // Extending a schema declared earlier in the same package is one schema, not
            // two: the file will carry it once, at whatever version it ends up at.
            try self.noteSchema(gpa, decl.id, decl.text);
        }
        if (failed) return error.ContentInvalid;
    }

    /// Registers a document's schema declarations, then checks its records against them.
    ///
    /// The two halves are separately callable because a package is many files: a record
    /// in the first may instantiate a schema declared in the last, so a caller with more
    /// than one document registers every schema before checking any record.
    pub fn addDocument(
        self: *Package,
        gpa: Allocator,
        doc: *const Document,
        registry: *Registry,
        diags: *Diagnostics,
    ) Error!void {
        // Both halves run even when the first one failed. A schema the registry refused
        // would otherwise hide every mistake in every record of the file, which turns one
        // bad `@schema` into a rebuild per record.
        var failed = false;
        self.registerSchemas(gpa, doc, registry, diags) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ContentInvalid => failed = true,
        };
        self.addRecords(gpa, doc, registry, diags) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ContentInvalid => failed = true,
        };
        if (failed) return error.ContentInvalid;
    }

    /// Checks every record in `doc` and appends the ones that pass.
    ///
    /// A record that fails is left out rather than stored half-checked; the call still
    /// visits the rest, because the point of collecting diagnostics is to report the
    /// whole file at once.
    pub fn addRecords(
        self: *Package,
        gpa: Allocator,
        doc: *const Document,
        registry: *Registry,
        diags: *Diagnostics,
    ) Error!void {
        var checker: Checker = .{
            .gpa = gpa,
            .arena = self.arena.allocator(),
            .pkg = self,
            .registry = registry,
            .diags = diags,
            .limits = self.limits,
        };
        defer checker.deinit();

        for (doc.records) |decl| try checker.record(decl);
        if (checker.failed) return error.ContentInvalid;
    }
};

/// The per-document state of one checking run.
const Checker = struct {
    gpa: Allocator,
    /// The package's arena. Everything a `Record` points at is copied into it, so a
    /// checked package outlives the document it was built from.
    arena: Allocator,
    pkg: *Package,
    registry: *Registry,
    diags: *Diagnostics,
    limits: Limits,

    /// The dotted path of the value being checked — `light.falloff`, `tags[3]` — built as
    /// the walk descends, so a complaint about a value inside an inline struct can name
    /// which one.
    path: std.ArrayList(u8) = .empty,
    /// Which of the schema's fields this record wrote. Distinct from "has a value in
    /// `values`", because a field whose value was refused has neither, and reporting it a
    /// second time as missing would be noise on top of the real message.
    written: std.ArrayList(bool) = .empty,
    failed: bool = false,

    fn deinit(self: *Checker) void {
        self.path.deinit(self.gpa);
        self.written.deinit(self.gpa);
    }

    fn record(self: *Checker, decl: RecordDecl) Allocator.Error!void {
        // `@patch` and `@remove` parse, because their syntax is fixed (§4.4) and freezing
        // it early is the point. Their *semantics* are M3's deliberate omission (§7): a
        // patch merges onto whatever record currently wins, which is a decision about
        // list fields nobody has made yet. Refusing is the honest reading — quietly
        // dropping a mod's patch would be worse than not loading it.
        switch (decl.kind) {
            .define => {},
            .patch => return self.err(decl.schema_origin, "'@patch' is not implemented yet; until it is, a later package overrides a record by restating it in full", .{}),
            .remove => return self.err(decl.schema_origin, "'@remove' is not implemented yet", .{}),
        }

        const handle = self.registry.find(decl.schema) orelse {
            return self.err(decl.schema_origin, "unknown schema '{s}'", .{decl.schema_text});
        };
        const schema = self.registry.get(handle).?.*;
        try self.pkg.noteSchema(self.gpa, decl.schema, decl.schema_text);

        if (self.pkg.by_id.get(decl.id.hash)) |existing_index| {
            const existing = self.pkg.list.items[existing_index];
            // Two spellings that hash the same is the failure ADR-0005 requires be a
            // build error naming both, rather than one record silently becoming another.
            if (!std.mem.eql(u8, existing.text, decl.text)) {
                return self.errNote(
                    decl.origin,
                    existing.origin,
                    "the other one",
                    "'{s}' and '{s}' hash to the same content id",
                    .{ decl.text, existing.text },
                );
            }
            return self.errNote(
                decl.origin,
                existing.origin,
                "already defined",
                "'{s}' is defined twice in this package; overriding happens between packages, not inside one",
                .{decl.text},
            );
        }

        const values = try self.arena.alloc(?Value, schema.fields.len);
        @memset(values, null);
        try self.written.resize(self.gpa, schema.fields.len);
        @memset(self.written.items, false);

        var ok = true;
        for (decl.fields, 0..) |field, i| {
            const index = schema.fieldIndex(field.name) orelse {
                ok = false;
                try self.err(field.name_origin, "schema '{s}' has no field '{s}'", .{ decl.schema_text, field.name });
                continue;
            };
            if (self.written.items[index]) {
                ok = false;
                // The earlier one is found by looking rather than remembered: this is the
                // error path, and a parallel array of origins on every record is a cost
                // paid by every correct record to speed up an incorrect one.
                var first = field.name_origin;
                for (decl.fields[0..i]) |earlier| {
                    if (std.mem.eql(u8, earlier.name, field.name)) {
                        first = earlier.name_origin;
                        break;
                    }
                }
                try self.errNote(field.name_origin, first, "first written here", "field '{s}' is written twice in one record", .{field.name});
                continue;
            }
            self.written.items[index] = true;

            self.path.clearRetainingCapacity();
            try self.path.appendSlice(self.gpa, field.name);
            values[index] = try self.normalize(
                schema.fields[index].type,
                field.value,
                field.value_origin,
                decl.schema_text,
                0,
            ) orelse {
                ok = false;
                continue;
            };
        }

        // Then what the record did not say. Reported after everything it did say, so the
        // messages read in the order the file does.
        for (schema.fields, 0..) |field, index| {
            if (self.written.items[index]) continue;
            switch (field.presence) {
                .optional => {},
                .default => |d| values[index] = try self.cloneValue(d, decl.origin, decl.schema_text, field.name) orelse {
                    ok = false;
                    continue;
                },
                .required => {
                    ok = false;
                    try self.err(decl.origin, "'{s}' is missing field '{s}', which schema '{s}' requires", .{ decl.text, field.name, decl.schema_text });
                },
            }
        }

        if (!ok) return;

        const index: u32 = @intCast(self.pkg.list.items.len);
        try self.pkg.list.append(self.gpa, .{
            .schema = handle,
            .schema_id = decl.schema,
            .id = decl.id,
            .text = try self.arena.dupe(u8, decl.text),
            .values = values,
            .origin = try self.ownOrigin(decl.origin),
        });
        errdefer _ = self.pkg.list.pop();
        try self.pkg.by_id.put(self.gpa, decl.id.hash, index);
    }

    /// Checks one value against one declared type and returns it copied into the package
    /// arena, laid out the way the schema declares. Null means a diagnostic was recorded.
    ///
    /// The structural walk lives here rather than in `schema.checkValue` because this is
    /// where the names are: `checkValue` can say that a value is the wrong type, and only
    /// this can say that it is `light.falloff`. The leaf rules are still `checkValue`'s
    /// alone, so there remains exactly one place that decides whether an integer fits an
    /// `f32`.
    fn normalize(
        self: *Checker,
        t: FieldType,
        v: Value,
        origin: Origin,
        schema_text: []const u8,
        depth: u32,
    ) Allocator.Error!?Value {
        if (depth >= self.limits.max_nesting_depth) {
            try self.err(origin, "'{s}' is nested more than {d} deep", .{ self.path.items, self.limits.max_nesting_depth });
            return null;
        }

        switch (t) {
            .list => |elem| {
                if (v != .list) return self.wrongType(t, v, origin, schema_text);
                if (v.list.len > self.limits.max_list_elements) {
                    try self.err(origin, "'{s}' has {d} elements, over the limit of {d}", .{ self.path.items, v.list.len, self.limits.max_list_elements });
                    return null;
                }
                const out = try self.arena.alloc(Value, v.list.len);
                var ok = true;
                for (v.list, out, 0..) |item, *dst, i| {
                    const mark = self.path.items.len;
                    // 24 bytes holds any index a `usize` can name; the fallback is there
                    // so a diagnostic can never be the thing that fails.
                    var buf: [24]u8 = undefined;
                    try self.path.appendSlice(self.gpa, std.fmt.bufPrint(&buf, "[{d}]", .{i}) catch "[?]");
                    const checked = try self.normalize(elem.*, item, origin, schema_text, depth + 1);
                    self.path.shrinkRetainingCapacity(mark);
                    if (checked) |c| dst.* = c else ok = false;
                }
                return if (ok) .{ .list = out } else null;
            },

            .nested => |fields| {
                if (v != .nested) return self.wrongType(t, v, origin, schema_text);
                var ok = true;

                // What was written that should not have been. Done first so that the
                // complaints follow the order the author wrote, not the schema's.
                for (v.nested, 0..) |named, i| {
                    if (indexOfNamed(v.nested[0..i], named.name) != null) {
                        ok = false;
                        try self.err(origin, "'{s}' writes '{s}' twice", .{ self.path.items, named.name });
                    } else if (indexOfField(fields, named.name) == null) {
                        ok = false;
                        try self.err(origin, "'{s}' has no field '{s}'", .{ self.path.items, named.name });
                    }
                }

                // Then the schema's own order, which is the order the result is in.
                var out: std.ArrayList(NamedValue) = .empty;
                defer out.deinit(self.gpa);
                try out.ensureTotalCapacity(self.gpa, fields.len);

                for (fields) |field| {
                    const name = try self.arena.dupe(u8, field.name);
                    if (indexOfNamed(v.nested, field.name)) |i| {
                        const mark = self.path.items.len;
                        if (mark != 0) try self.path.append(self.gpa, '.');
                        try self.path.appendSlice(self.gpa, field.name);
                        const checked = try self.normalize(field.type, v.nested[i].value, origin, schema_text, depth + 1);
                        self.path.shrinkRetainingCapacity(mark);
                        if (checked) |c| {
                            try out.append(self.gpa, .{ .name = name, .value = c });
                        } else ok = false;
                        continue;
                    }
                    switch (field.presence) {
                        // An absent optional is simply left out. It is the one place a
                        // checked value is not positional, and it is affordable precisely
                        // because an inline struct is small enough to walk (§3).
                        .optional => {},
                        .default => |d| {
                            const c = try self.cloneValue(d, origin, schema_text, field.name) orelse {
                                ok = false;
                                continue;
                            };
                            try out.append(self.gpa, .{ .name = name, .value = c });
                        },
                        .required => {
                            ok = false;
                            try self.err(origin, "'{s}' is missing field '{s}'", .{ self.path.items, field.name });
                        },
                    }
                }

                return if (ok) .{ .nested = try self.arena.dupe(NamedValue, out.items) } else null;
            },

            else => {
                schema_mod.checkValue(t, v, self.limits, depth) catch |e| switch (e) {
                    error.WrongType => return self.wrongType(t, v, origin, schema_text),
                    error.IntegerOutOfRange => {
                        try self.err(origin, "field '{s}' of schema '{s}' expects {f}, and {d} is outside its range", .{ self.path.items, schema_text, t, v.int });
                        return null;
                    },
                    error.FloatNotExact => {
                        try self.err(origin, "field '{s}' of schema '{s}' expects {f}, which cannot hold {d} exactly", .{ self.path.items, schema_text, t, v.int });
                        return null;
                    },
                    else => return self.wrongType(t, v, origin, schema_text),
                };
                return try self.cloneValue(v, origin, schema_text, self.path.items);
            },
        }
    }

    fn wrongType(
        self: *Checker,
        t: FieldType,
        v: Value,
        origin: Origin,
        schema_text: []const u8,
    ) Allocator.Error!?Value {
        try self.err(origin, "field '{s}' of schema '{s}' expects {f}, found {s}", .{ self.path.items, schema_text, t, kindOf(v) });
        return null;
    }

    /// Copies a value into the package arena, reporting the structural limits rather than
    /// returning them: a default too deep to copy is a schema problem the content author
    /// cannot fix, and it should say so where the content is.
    fn cloneValue(
        self: *Checker,
        v: Value,
        origin: Origin,
        schema_text: []const u8,
        name: []const u8,
    ) Allocator.Error!?Value {
        return v.clone(self.arena, self.limits) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => {
                try self.err(origin, "field '{s}' of schema '{s}' is too large or too deeply nested to store", .{ name, schema_text });
                return null;
            },
        };
    }

    fn ownOrigin(self: *Checker, origin: Origin) Allocator.Error!Origin {
        return .{
            .file = try self.arena.dupe(u8, origin.file),
            .line = origin.line,
            .column = origin.column,
            .length = origin.length,
            .line_text = try self.arena.dupe(u8, origin.line_text),
        };
    }

    fn err(self: *Checker, origin: Origin, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        self.failed = true;
        try self.diags.addFmt(self.gpa, .err, origin.location(), origin.length, origin.line_text, fmt, args);
    }

    fn errNote(
        self: *Checker,
        origin: Origin,
        note_origin: Origin,
        note_message: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        self.failed = true;
        const message = try std.fmt.allocPrint(self.gpa, fmt, args);
        defer self.gpa.free(message);
        try self.diags.add(self.gpa, .{
            .severity = .err,
            .location = origin.location(),
            .length = origin.length,
            .source_line = origin.line_text,
            .message = message,
            .note = .{ .location = note_origin.location(), .message = note_message },
        });
    }
};

/// What a value *is*, in the same words the schema uses for what it should have been.
fn kindOf(v: Value) []const u8 {
    return switch (v) {
        .bool => "bool",
        .int => "integer",
        .float => "float",
        .string => "string",
        .id => "id",
        .list => "list",
        .nested => "{ ... }",
    };
}

fn indexOfField(fields: []const Field, name: []const u8) ?usize {
    for (fields, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return i;
    return null;
}

fn indexOfNamed(values: []const NamedValue, name: []const u8) ?usize {
    for (values, 0..) |nv, i| if (std.mem.eql(u8, nv.name, name)) return i;
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Parses, registers and checks — and frees the document before returning.
///
/// Freeing it here is not tidiness: it means every test below reads a package whose
/// source document is gone, so "a checked package owns everything it points at" is
/// asserted by all of them rather than by one.
fn compileInto(
    source: []const u8,
    pkg: *Package,
    registry: *Registry,
    diags: *Diagnostics,
) Error!void {
    var doc = try parser_mod.parse(
        testing.allocator,
        "light.fdt",
        source,
        .{ .namespace = "foundry" },
        diags,
    );
    defer doc.deinit(testing.allocator);
    try pkg.addDocument(testing.allocator, &doc, registry, diags);
}

fn render(diags: *const Diagnostics, buf: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    try diags.render(&writer);
    return writer.buffered();
}

/// Sets up the three pieces every test needs and tears them down in one place.
const Harness = struct {
    registry: Registry,
    diags: Diagnostics,
    pkg: Package,

    fn init() !Harness {
        return .{
            .registry = .init(testing.allocator, .default),
            .diags = .init(testing.allocator, .default),
            .pkg = try .init(testing.allocator, "foundry:core", 1, .default),
        };
    }

    fn deinit(self: *Harness) void {
        self.pkg.deinit(testing.allocator);
        self.diags.deinit(testing.allocator);
        self.registry.deinit(testing.allocator);
    }

    fn compile(self: *Harness, source: []const u8) Error!void {
        return compileInto(source, &self.pkg, &self.registry, &self.diags);
    }

    fn expectFailure(self: *Harness, source: []const u8, buf: []u8) ![]const u8 {
        try testing.expectError(error.ContentInvalid, self.compile(source));
        return render(&self.diags, buf);
    }
};

test "a record becomes values in schema order, with defaults filled and optionals absent" {
    var h = try Harness.init();
    defer h.deinit();

    try h.compile(
        \\@schema item {
        \\    name    string
        \\    weight  f32       (default 0.5)
        \\    tags    [string]  (optional)
        \\}
        \\
        \\item foundry:item.torch {
        \\    tags ["light" "fuel"]
        \\    name "Torch"
        \\}
    );

    try testing.expectEqual(@as(u32, 1), h.pkg.count());
    const torch = h.pkg.lookup(ContentId.fromString("foundry:item.torch")).?;
    try testing.expectEqualStrings("foundry:item.torch", torch.text);

    // Schema order, not the order the author wrote them in.
    const schema = h.registry.get(torch.schema).?.*;
    try testing.expectEqual(@as(usize, 3), torch.values.len);
    try testing.expectEqualStrings("Torch", torch.value(schema, 0).?.string);
    try testing.expectEqual(@as(f64, 0.5), torch.value(schema, 1).?.float);
    try testing.expectEqual(@as(usize, 2), torch.value(schema, 2).?.list.len);

    // A default is filled; an absent optional stays absent, and the two are different
    // answers to different questions.
    try h.compile("item foundry:item.ash { name \"Ash\" }");
    const ash = h.pkg.lookup(ContentId.fromString("foundry:item.ash")).?;
    try testing.expectEqual(@as(f64, 0.5), ash.value(schema, 1).?.float);
    try testing.expect(ash.value(schema, 2) == null);
}

test "a type error reads exactly as the design document says it should" {
    var h = try Harness.init();
    defer h.deinit();

    var buf: [1024]u8 = undefined;
    const rendered = try h.expectFailure(
        \\@schema item {
        \\    weight f32
        \\}
        \\
        \\
        \\item foundry:item.torch {
        \\    weight  "0.5"
        \\}
    , &buf);

    try testing.expectEqualStrings(
        \\light.fdt:7:13: error: field 'weight' of schema 'foundry:item' expects f32, found string
        \\    weight  "0.5"
        \\            ^~~~~
        \\
    , rendered);
    try testing.expectEqual(@as(u32, 0), h.pkg.count());
}

test "a number that does not fit says so in the terms the schema used" {
    var h = try Harness.init();
    defer h.deinit();

    var buf: [1024]u8 = undefined;
    const rendered = try h.expectFailure(
        \\@schema item { stack u32  size f32 }
        \\item foundry:item.torch { stack -1  size 16777217 }
    , &buf);

    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "expects u32, and -1 is outside its range"));
    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "expects f32, which cannot hold 16777217 exactly"));
}

test "a value inside an inline struct is named by its path" {
    var h = try Harness.init();
    defer h.deinit();

    var buf: [2048]u8 = undefined;
    const rendered = try h.expectFailure(
        \\@schema item {
        \\    light  { radius f32  falloff f32 }
        \\    grid   [[i32]]
        \\}
        \\item foundry:item.torch {
        \\    light { radius 6.0  falloff "steep" }
        \\    grid  [[1 2] [3 "four"]]
        \\}
    , &buf);

    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "field 'light.falloff' of schema 'foundry:item' expects f32, found string"));
    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "field 'grid[1][1]' of schema 'foundry:item' expects i32, found string"));
}

test "unknown, repeated and missing fields are three different complaints" {
    var h = try Harness.init();
    defer h.deinit();

    var buf: [2048]u8 = undefined;
    const rendered = try h.expectFailure(
        \\@schema item {
        \\    name    string
        \\    weight  f32
        \\}
        \\item foundry:item.torch {
        \\    wieght  0.5
        \\    name    "Torch"
        \\    name    "Torch again"
        \\}
    , &buf);

    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "schema 'foundry:item' has no field 'wieght'"));
    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "field 'name' is written twice in one record"));
    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "first written here at light.fdt:7:5"));
    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "'foundry:item.torch' is missing field 'weight', which schema 'foundry:item' requires"));
}

test "an unknown schema points at the schema name, not at the record" {
    var h = try Harness.init();
    defer h.deinit();

    var buf: [1024]u8 = undefined;
    const rendered = try h.expectFailure("weapon foundry:item.sword { }", &buf);

    try testing.expect(std.mem.startsWith(u8, rendered, "light.fdt:1:1: error: unknown schema 'foundry:weapon'"));
}

test "a record defined twice in one package is refused, and the note finds the first" {
    var h = try Harness.init();
    defer h.deinit();

    var buf: [1024]u8 = undefined;
    const rendered = try h.expectFailure(
        \\@schema item { name string }
        \\item foundry:item.torch { name "Torch" }
        \\item foundry:item.torch { name "Also torch" }
    , &buf);

    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "'foundry:item.torch' is defined twice in this package"));
    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "already defined at light.fdt:2:6"));
    // The first one is still there: a duplicate is refused, not a poison pill.
    try testing.expectEqual(@as(u32, 1), h.pkg.count());
}

test "an inline struct comes out in schema order, with its own defaults filled" {
    var h = try Harness.init();
    defer h.deinit();

    try h.compile(
        \\@schema item {
        \\    light { radius f32  falloff f32 (default 2.0)  warm bool (optional) }
        \\}
        \\item foundry:item.torch {
        \\    light { falloff 3.0  radius 6.0 }
        \\}
    );

    const torch = h.pkg.records()[0];
    const light = torch.values[0].?.nested;
    try testing.expectEqual(@as(usize, 2), light.len);
    try testing.expectEqualStrings("radius", light[0].name);
    try testing.expectEqual(@as(f64, 6.0), light[0].value.float);
    try testing.expectEqualStrings("falloff", light[1].name);
    try testing.expectEqual(@as(f64, 3.0), light[1].value.float);

    // The absent optional is left out rather than given a value, which is the one place a
    // checked value is scanned by name instead of indexed.
    try h.compile("item foundry:item.ash { light { radius 1.0 } }");
    const ash = h.pkg.records()[1].values[0].?.nested;
    try testing.expectEqual(@as(usize, 2), ash.len);
    try testing.expectEqualStrings("falloff", ash[1].name);
    try testing.expectEqual(@as(f64, 2.0), ash[1].value.float);
}

test "@patch and @remove parse, and say plainly that they do not load yet" {
    var h = try Harness.init();
    defer h.deinit();

    var buf: [1024]u8 = undefined;
    const rendered = try h.expectFailure(
        \\@schema item { name string }
        \\@patch foundry:item.torch { name "Lighter torch" }
        \\@remove foundry:item.ash
    , &buf);

    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "'@patch' is not implemented yet"));
    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "'@remove' is not implemented yet"));
}

test "a schema the registry refuses is reported against its declaration" {
    var h = try Harness.init();
    defer h.deinit();

    var buf: [1024]u8 = undefined;
    // Two versions of one schema, the second no higher than the first.
    const rendered = try h.expectFailure(
        \\@schema item { name string }
        \\@schema item { name string  weight f32 (optional) }
    , &buf);

    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "light.fdt:2:9: error: schema 'foundry:item' is already registered"));

    // A field added at a higher version is the additive change that is allowed.
    var h2 = try Harness.init();
    defer h2.deinit();
    try h2.compile(
        \\@schema item { name string }
        \\@schema item { name string  weight f32 (since 2) (default 0.5) }
        \\item foundry:item.torch { name "Torch" }
    );
    const schema = h2.registry.lookup(SchemaId.fromStringUnchecked("foundry:item")).?.*;
    try testing.expectEqual(@as(u32, 2), schema.version);
    try testing.expectEqual(@as(f64, 0.5), h2.pkg.records()[0].value(schema, 1).?.float);
}

test "a field appended by a later schema version reads as its default in older content" {
    var h = try Harness.init();
    defer h.deinit();

    try h.compile(
        \\@schema item { name string }
        \\item foundry:item.torch { name "Torch" }
    );
    const torch = h.pkg.records()[0];
    try testing.expectEqual(@as(usize, 1), torch.values.len);

    // The schema grows behind the handle the record already holds (I1).
    try h.compile("@schema item { name string  weight f32 (since 2) (default 0.5) }");
    const schema = h.registry.get(torch.schema).?.*;
    try testing.expectEqual(@as(usize, 2), schema.fields.len);
    try testing.expectEqual(@as(f64, 0.5), torch.value(schema, 1).?.float);
    // And past the end of the schema is absent, not a crash.
    try testing.expect(torch.value(schema, 7) == null);
}

test "records keep the order they were written in, which is the order they merge in" {
    var h = try Harness.init();
    defer h.deinit();

    try h.compile(
        \\@schema item { name string }
        \\item foundry:item.torch { name "Torch" }
        \\item foundry:item.ash   { name "Ash" }
        \\item foundry:item.lamp  { name "Lamp" }
    );

    try testing.expectEqual(@as(u32, 3), h.pkg.count());
    try testing.expectEqualStrings("foundry:item.torch", h.pkg.records()[0].text);
    try testing.expectEqualStrings("foundry:item.ash", h.pkg.records()[1].text);
    try testing.expectEqualStrings("foundry:item.lamp", h.pkg.records()[2].text);
    try testing.expectEqual(@as(u32, 1), h.pkg.find(ContentId.fromString("foundry:item.ash")).?);
    try testing.expect(h.pkg.find(ContentId.fromString("foundry:item.nothing")) == null);
}

test "a package carries the schemas its records use, not only the ones it declares" {
    var h = try Harness.init();
    defer h.deinit();

    // A schema from somewhere else — the base game, as far as this package knows.
    _ = try h.registry.register(testing.allocator, .{
        .id = SchemaId.fromStringUnchecked("other:tile"),
        .version = 1,
        .fields = &.{.{ .name = "solid", .type = .bool }},
    });

    try h.compile(
        \\@schema item { name string }
        \\item foundry:item.torch { name "Torch" }
        \\other:tile foundry:tile.wall { solid true }
    );

    // Both, in declaration order then first-use order: the declared one is what the
    // package defines, and the used one is what its bytes are laid out against, which the
    // compiled file has to state for itself (§6).
    try testing.expectEqual(@as(usize, 2), h.pkg.schemas.items.len);
    try testing.expectEqualStrings("foundry:item", h.pkg.schemas.items[0].text);
    try testing.expectEqualStrings("other:tile", h.pkg.schemas.items[1].text);
}

test "every mistake in a file is reported, not just the first" {
    var h = try Harness.init();
    defer h.deinit();

    var buf: [4096]u8 = undefined;
    const rendered = try h.expectFailure(
        \\@schema item { name string  weight f32 }
        \\item foundry:item.a { name 1      weight 0.5 }
        \\item foundry:item.b { name "B"    weight "x" }
        \\item foundry:item.c { name "C"    weight 0.5 }
        \\item foundry:item.d { name "D" }
    , &buf);
    _ = rendered;

    try testing.expectEqual(@as(usize, 3), h.diags.count());
    // The one good record is kept; the pass does not abandon the file at the first bad
    // one, and does not store the bad ones either.
    try testing.expectEqual(@as(u32, 1), h.pkg.count());
    try testing.expectEqualStrings("foundry:item.c", h.pkg.records()[0].text);
}

test "a bad schema does not hide the mistakes in the records below it" {
    var h = try Harness.init();
    defer h.deinit();

    var buf: [2048]u8 = undefined;
    const rendered = try h.expectFailure(
        \\@schema item { name string }
        \\@schema item { label string }
        \\item foundry:item.torch { name 42 }
    , &buf);

    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "is already registered"));
    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "expects string, found integer"));
}
