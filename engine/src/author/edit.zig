//! Revisioned, typed edits over a bounded authoring workspace.
//!
//! Commands turn schema-aware intent into one source splice, parse and
//! validate the candidate, and install it only after every check and history allocation has
//! succeeded. Source bytes remain authoritative (ADR-0043). Persistence and isolated builds
//! live beside this module; ABI publication deliberately does not live here.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");

const compiler = @import("compiler.zig");
const dependency = @import("dependency.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Diagnostics = data.Diagnostics;
const Field = data.Field;
const FieldType = data.FieldType;
const NamedValue = data.NamedValue;
const Schema = data.Schema;
const Value = data.Value;

/// One source file held by a workspace.
pub const Document = struct {
    path: []const u8,
    /// Paths discovered at open live in the workspace arena; a document created later owns
    /// its path directly because an arena allocation cannot be rolled back on a failed add.
    owns_path: bool = false,
    /// Current draft bytes. Owned independently of `baseline` after open as well as after
    /// edits, so dirty state is a byte comparison and never an undo-stack position.
    bytes: []u8,
    /// The last bytes read from or successfully written to disk.
    baseline: []u8,
    disk: platform.os.FileInfo,
    /// False for a new in-memory document until its create-if-absent Save succeeds.
    on_disk: bool = true,
    /// Set when a save/build comparison sees bytes or inventory that no longer match the
    /// baseline. The draft and the disk copy are both retained until an explicit refresh.
    externally_changed: bool = false,
    /// Syntax could be parsed under the workspace's namespace and import set.
    parseable: bool = false,
    /// The source is syntactically and structurally safe for typed commands. An incomplete
    /// draft remains editable; an unknown schema, wrong type or unsupported directive does
    /// not.
    editable: bool = false,

    pub fn dirty(self: Document) bool {
        return !std.mem.eql(u8, self.bytes, self.baseline);
    }

    pub fn deinit(self: *Document, gpa: Allocator) void {
        if (self.owns_path) gpa.free(self.path);
        gpa.free(self.bytes);
        gpa.free(self.baseline);
        self.* = undefined;
    }
};

/// A record written in one source document. `record` is the index in the parser's record
/// array, not a content id: the expected workspace revision makes the pair unambiguous.
pub const RecordRef = struct {
    document: u32,
    record: u32,
};

/// A record in one host-granted dependency package.
pub const DependencyRecordRef = struct {
    package: u32,
    record: u32,
};

/// One structural step from a record to a field or list element.
pub const Selector = union(enum) {
    field: u32,
    item: u32,
};

/// A typed value plus the spellings of any content IDs it contains. Values store hashes;
/// source stores names, so a caller entering a new ID must provide its spelling rather than
/// asking the service to guess it.
pub const TypedValue = struct {
    value: Value,
    id_spellings: []const []const u8 = &.{},
};

/// A selection the service can restore after a command, Undo or Redo. The path is owned by
/// the history entry and is borrowed until the next history mutation.
pub const Locator = struct {
    document: u32,
    record: ?ContentId = null,
    path: []const Selector = &.{},
};

pub const Result = struct {
    revision: u64,
    selection: Locator,
};

/// Bounds owned by Step 3. Source-discovery and parser limits remain in `workspace.Limits`.
pub const Limits = struct {
    max_source_bytes: usize,
    max_total_source_bytes: usize,
    max_document_bytes: usize,
    max_history_commands: u32,
    max_history_bytes: usize,
    content: data.Limits,
};

pub const Error = error{
    StaleRevision,
    RevisionExhausted,
    InvalidDocument,
    InvalidDocumentName,
    DuplicateDocument,
    ReadOnlyDocument,
    InvalidRecord,
    InvalidDependencyRecord,
    InvalidPath,
    NotPresent,
    NotAList,
    DuplicateRecord,
    SourceInvalid,
    SchemaUnavailable,
    HistoryEmpty,
    HistoryLimit,
    DocumentBudget,
    NoChange,
    DependencyInvalid,
    WriteNotGranted,
} || data.splice.Error;

/// The state which outlives one command. Parsed documents do not: they are operation
/// snapshots bounded by source size, which prevents an import-heavy package from retaining
/// a parse tree for every possible root file.
pub const State = struct {
    registry: data.Registry,
    history: History = .{},
    revision: u64 = 1,
    available: bool = false,

    pub fn init(gpa: Allocator, limits: data.Limits) State {
        return .{ .registry = data.Registry.init(gpa, limits) };
    }

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.history.deinit(gpa);
        self.registry.deinit(gpa);
        self.* = undefined;
    }

    /// Builds the schema registry and classifies every discovered source. Content mistakes
    /// are diagnostics beside a workspace which still opens; allocation failure is the only
    /// failure that prevents classification.
    pub fn prepare(
        self: *State,
        gpa: Allocator,
        documents: []Document,
        dependencies: *const dependency.Set,
        package_name: ?[]const u8,
        limits: Limits,
        diags: *Diagnostics,
    ) Allocator.Error!void {
        compiler.registerAvailableSchemas(gpa, dependencies, &self.registry, diags) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                for (documents) |*document| {
                    document.parseable = false;
                    document.editable = false;
                }
                return;
            },
        };

        const namespace = namespaceOf(package_name);
        const parsed = try gpa.alloc(?data.Document, documents.len);
        defer gpa.free(parsed);
        @memset(parsed, null);
        defer for (parsed) |*slot| if (slot.*) |*doc| doc.deinit(gpa);

        for (documents, 0..) |*document, i| {
            const doc = parseDocument(gpa, documents, namespace, limits.content, @intCast(i), null, diags) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ContentInvalid => {
                    document.parseable = false;
                    document.editable = false;
                    continue;
                },
            };
            document.parseable = true;
            document.editable = true;
            parsed[i] = doc;
        }

        // Local declarations come after dependencies and engine schemas, as in compile().
        var package = data.Package.init(gpa, package_name orelse "package:workspace", 1, limits.content) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        defer package.deinit(gpa);
        for (parsed, documents) |*slot, *document| {
            const doc = if (slot.*) |*value| value else continue;
            package.registerSchemas(gpa, doc, &self.registry, diags) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ContentInvalid => document.editable = false,
            };
        }

        var seen: std.AutoHashMapUnmanaged(u64, SeenRecord) = .empty;
        defer seen.deinit(gpa);
        for (parsed, documents, 0..) |*slot, *document, document_index| {
            const doc = if (slot.*) |*value| value else continue;
            const validation = try validateDocument(gpa, doc, &self.registry, limits.content, diags);
            if (validation == .invalid) document.editable = false;

            for (doc.records, 0..) |record, record_index| {
                if (!isLocal(record)) continue;
                if (seen.get(record.id.hash)) |first| {
                    try diags.addFmt(gpa, .err, record.origin.location(), record.origin.length, record.origin.line_text, "'{s}' is already defined in '{s}'", .{ record.text, documents[first.document].path });
                    document.editable = false;
                    continue;
                }
                try seen.put(gpa, record.id.hash, .{
                    .document = @intCast(document_index),
                    .record = @intCast(record_index),
                    .text = record.text,
                });
            }
        }

        self.available = true;
    }
};

/// Everything an operation borrows from its workspace.
pub const Context = struct {
    gpa: Allocator,
    documents: []Document,
    dependencies: *const dependency.Set,
    state: *State,
    package_name: ?[]const u8,
    limits: Limits,

    fn namespace(self: Context) []const u8 {
        return namespaceOf(self.package_name);
    }

    fn begin(self: Context, expected_revision: u64) Error!void {
        if (!self.state.available) return error.SchemaUnavailable;
        if (expected_revision != self.state.revision) return error.StaleRevision;
        if (self.state.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
    }
};

/// An owned parse used for source-tree reads. Its values and spans remain valid until
/// `deinit`; schema metadata is borrowed from the workspace registry.
pub const Inspection = struct {
    gpa: Allocator,
    document: data.Document,
    declaration_index: u32,
    schema: *const Schema,

    pub fn deinit(self: *Inspection) void {
        self.document.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn node(self: *const Inspection, path: []const Selector) Error!NodeInfo {
        const resolved = try resolveNode(self.document.records[self.declaration_index], self.schema.*, path);
        return .{
            .field_type = resolved.field_type,
            .presence = if (resolved.declared_field) |field| field.presence else null,
            .authored = resolved.value != null,
            .value = resolved.value,
        };
    }
};

pub const NodeInfo = struct {
    field_type: FieldType,
    /// Null for a list element. Required/optional/default remain distinct for fields.
    presence: ?data.Presence,
    authored: bool,
    value: ?Value,
};

pub fn inspect(ctx: Context, ref: RecordRef, diags: *Diagnostics) Error!Inspection {
    const document = documentFor(ctx, ref.document) catch |err| return err;
    if (!document.editable) return error.ReadOnlyDocument;
    var parsed = parseDocument(ctx.gpa, ctx.documents, ctx.namespace(), ctx.limits.content, ref.document, null, diags) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ContentInvalid => return error.SourceInvalid,
    };
    errdefer parsed.deinit(ctx.gpa);
    const declaration = localRecord(&parsed, ref.record) orelse return error.InvalidRecord;
    if (declaration.kind != .define) return error.InvalidRecord;
    const schema = ctx.state.registry.lookup(declaration.schema) orelse return error.SchemaUnavailable;
    return .{
        .gpa = ctx.gpa,
        .document = parsed,
        .declaration_index = ref.record,
        .schema = schema,
    };
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

pub fn createRecord(
    ctx: Context,
    expected_revision: u64,
    document_index: u32,
    schema_text: []const u8,
    id_text: []const u8,
    diags: *Diagnostics,
) Error!Result {
    try ctx.begin(expected_revision);
    try requireEditable(ctx, document_index);

    var snapshot = try Snapshot.init(ctx);
    defer snapshot.deinit();
    try snapshot.addSpelling(schema_text);
    try snapshot.addSpelling(id_text);

    const schema_id = data.SchemaId.parse(schema_text) catch return error.InvalidId;
    const schema = ctx.state.registry.lookup(schema_id) orelse return error.SchemaUnavailable;
    const id = data.contentId(id_text) catch return error.InvalidId;
    try ensureUnique(&snapshot, null, id, id_text);

    const values = try ctx.gpa.alloc(?Value, schema.fields.len);
    defer ctx.gpa.free(values);
    @memset(values, null);
    var record: std.ArrayList(u8) = .empty;
    defer record.deinit(ctx.gpa);
    try data.emit.writeRecord(&record, ctx.gpa, .{
        .spellings = &snapshot.spellings,
        .newline = data.emit.Newline.detect(ctx.documents[document_index].bytes),
        .limits = ctx.limits.content,
    }, schema_text, id_text, schema.fields, values);

    const text = try rootText(&snapshot, ctx, document_index);
    var edit = try data.splice.appendRecord(ctx.gpa, text, record.items);
    defer edit.deinit(ctx.gpa);
    return commit(ctx, &snapshot, document_index, edit, .{ .document = document_index }, .{ .document = document_index, .record = id }, diags);
}

pub fn duplicateRecord(
    ctx: Context,
    expected_revision: u64,
    source: RecordRef,
    destination_document: u32,
    new_id_text: []const u8,
    diags: *Diagnostics,
) Error!Result {
    try ctx.begin(expected_revision);
    try requireEditable(ctx, source.document);
    try requireEditable(ctx, destination_document);

    var snapshot = try Snapshot.init(ctx);
    defer snapshot.deinit();
    try snapshot.addSpelling(new_id_text);
    const declaration = try recordIn(&snapshot, source);
    const source_info = declaration.source orelse return error.InvalidRecord;
    const new_id = data.contentId(new_id_text) catch return error.InvalidId;
    try ensureUnique(&snapshot, null, new_id, new_id_text);

    const source_text = try rootText(&snapshot, ctx, source.document);
    const copy = try data.splice.duplicateRecord(ctx.gpa, .{
        .spellings = &snapshot.spellings,
        .limits = ctx.limits.content,
    }, source_text, source_info.*, new_id_text);
    defer ctx.gpa.free(copy);
    const destination = try rootText(&snapshot, ctx, destination_document);
    var edit = try data.splice.appendRecord(ctx.gpa, destination, copy);
    defer edit.deinit(ctx.gpa);
    return commit(ctx, &snapshot, destination_document, edit, .{ .document = source.document, .record = declaration.id }, .{ .document = destination_document, .record = new_id }, diags);
}

pub fn createOverride(
    ctx: Context,
    expected_revision: u64,
    destination_document: u32,
    dependency_record: DependencyRecordRef,
    diags: *Diagnostics,
) Error!Result {
    try ctx.begin(expected_revision);
    try requireEditable(ctx, destination_document);

    var snapshot = try Snapshot.init(ctx);
    defer snapshot.deinit();
    const packages = ctx.dependencies.items();
    if (dependency_record.package >= packages.len) return error.InvalidDependencyRecord;
    const package = &packages[dependency_record.package];
    const view = package.reader.record(dependency_record.record) orelse return error.InvalidDependencyRecord;
    const schema = package.reader.schemaFor(view.schema_id) orelse return error.DependencyInvalid;
    const schema_text = schemaName(&package.reader, view.schema_id) orelse return error.DependencyInvalid;
    try ensureUnique(&snapshot, null, view.id, view.name);

    var scratch: core.Arena = .init(ctx.gpa);
    defer scratch.deinit();
    const values = try scratch.allocator().alloc(?Value, schema.fields.len);
    const fields = package.reader.fieldsOf(view, schema.*);
    for (values, 0..) |*slot, i| {
        slot.* = fields.valueAt(scratch.allocator(), @intCast(i)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.DependencyInvalid,
        };
    }

    var record: std.ArrayList(u8) = .empty;
    defer record.deinit(ctx.gpa);
    try data.emit.writeRecord(&record, ctx.gpa, .{
        .spellings = &snapshot.spellings,
        .newline = data.emit.Newline.detect(ctx.documents[destination_document].bytes),
        .limits = ctx.limits.content,
    }, schema_text, view.name, schema.fields, values);

    const destination = try rootText(&snapshot, ctx, destination_document);
    var edit = try data.splice.appendRecord(ctx.gpa, destination, record.items);
    defer edit.deinit(ctx.gpa);
    return commit(ctx, &snapshot, destination_document, edit, .{ .document = destination_document }, .{ .document = destination_document, .record = view.id }, diags);
}

pub fn deleteRecord(
    ctx: Context,
    expected_revision: u64,
    ref: RecordRef,
    diags: *Diagnostics,
) Error!Result {
    try ctx.begin(expected_revision);
    try requireEditable(ctx, ref.document);
    var snapshot = try Snapshot.init(ctx);
    defer snapshot.deinit();
    const declaration = try recordIn(&snapshot, ref);
    const source = declaration.source orelse return error.InvalidRecord;
    const text = try rootText(&snapshot, ctx, ref.document);
    var edit = try data.splice.removeRecord(ctx.gpa, text, source.*);
    defer edit.deinit(ctx.gpa);
    return commit(ctx, &snapshot, ref.document, edit, .{ .document = ref.document, .record = declaration.id }, .{ .document = ref.document }, diags);
}

pub fn setValue(
    ctx: Context,
    expected_revision: u64,
    ref: RecordRef,
    path: []const Selector,
    input: TypedValue,
    diags: *Diagnostics,
) Error!Result {
    try ctx.begin(expected_revision);
    try requireEditable(ctx, ref.document);
    var snapshot = try Snapshot.init(ctx);
    defer snapshot.deinit();
    for (input.id_spellings) |spelling| try snapshot.addSpelling(spelling);
    const declaration = try recordIn(&snapshot, ref);
    const schema = ctx.state.registry.lookup(declaration.schema) orelse return error.SchemaUnavailable;
    const resolved = try resolveNode(declaration.*, schema.*, path);
    const text = try rootText(&snapshot, ctx, ref.document);
    const options: data.splice.Options = .{ .spellings = &snapshot.spellings, .limits = ctx.limits.content };
    var edit = if (resolved.source) |source|
        try data.splice.replaceValue(ctx.gpa, options, text, source, resolved.field_type, input.value)
    else if (resolved.parent_fields) |parent|
        try data.splice.insertField(ctx.gpa, options, text, parent.body, parent.sources, resolved.declared_field.?.name, resolved.field_type, input.value)
    else
        return error.InvalidPath;
    defer edit.deinit(ctx.gpa);
    const id = declaration.id;
    const locator: Locator = .{ .document = ref.document, .record = id, .path = path };
    return commit(ctx, &snapshot, ref.document, edit, locator, locator, diags);
}

pub fn unsetField(
    ctx: Context,
    expected_revision: u64,
    ref: RecordRef,
    path: []const Selector,
    diags: *Diagnostics,
) Error!Result {
    try ctx.begin(expected_revision);
    try requireEditable(ctx, ref.document);
    var snapshot = try Snapshot.init(ctx);
    defer snapshot.deinit();
    const declaration = try recordIn(&snapshot, ref);
    const schema = ctx.state.registry.lookup(declaration.schema) orelse return error.SchemaUnavailable;
    const resolved = try resolveNode(declaration.*, schema.*, path);
    const parent = resolved.parent_fields orelse return error.InvalidPath;
    const index = resolved.source_index orelse return error.NotPresent;
    const text = try rootText(&snapshot, ctx, ref.document);
    var edit = try data.splice.removeField(ctx.gpa, text, parent.body, parent.sources, index);
    defer edit.deinit(ctx.gpa);
    const locator: Locator = .{ .document = ref.document, .record = declaration.id, .path = path };
    return commit(ctx, &snapshot, ref.document, edit, locator, locator, diags);
}

pub fn insertListItem(
    ctx: Context,
    expected_revision: u64,
    ref: RecordRef,
    path: []const Selector,
    index: u32,
    input: TypedValue,
    diags: *Diagnostics,
) Error!Result {
    try ctx.begin(expected_revision);
    try requireEditable(ctx, ref.document);
    var snapshot = try Snapshot.init(ctx);
    defer snapshot.deinit();
    for (input.id_spellings) |spelling| try snapshot.addSpelling(spelling);
    const declaration = try recordIn(&snapshot, ref);
    const schema = ctx.state.registry.lookup(declaration.schema) orelse return error.SchemaUnavailable;
    const resolved = try resolveNode(declaration.*, schema.*, path);
    if (resolved.field_type != .list) return error.NotAList;
    const source = resolved.source orelse return error.NotPresent;
    const text = try rootText(&snapshot, ctx, ref.document);
    var edit = try data.splice.insertItem(ctx.gpa, .{
        .spellings = &snapshot.spellings,
        .limits = ctx.limits.content,
    }, text, source, index, resolved.field_type.list.*, input.value);
    defer edit.deinit(ctx.gpa);
    const locator: Locator = .{ .document = ref.document, .record = declaration.id, .path = path };
    return commit(ctx, &snapshot, ref.document, edit, locator, locator, diags);
}

pub fn removeListItem(
    ctx: Context,
    expected_revision: u64,
    ref: RecordRef,
    path: []const Selector,
    index: u32,
    diags: *Diagnostics,
) Error!Result {
    return changeList(ctx, expected_revision, ref, path, .{ .remove = index }, diags);
}

pub fn moveListItem(
    ctx: Context,
    expected_revision: u64,
    ref: RecordRef,
    path: []const Selector,
    from: u32,
    to: u32,
    diags: *Diagnostics,
) Error!Result {
    if (from == to) return error.NoChange;
    return changeList(ctx, expected_revision, ref, path, .{ .move = .{ .from = from, .to = to } }, diags);
}

const ListChange = union(enum) {
    remove: u32,
    move: struct { from: u32, to: u32 },
};

fn changeList(ctx: Context, expected_revision: u64, ref: RecordRef, path: []const Selector, change: ListChange, diags: *Diagnostics) Error!Result {
    try ctx.begin(expected_revision);
    try requireEditable(ctx, ref.document);
    var snapshot = try Snapshot.init(ctx);
    defer snapshot.deinit();
    const declaration = try recordIn(&snapshot, ref);
    const schema = ctx.state.registry.lookup(declaration.schema) orelse return error.SchemaUnavailable;
    const resolved = try resolveNode(declaration.*, schema.*, path);
    if (resolved.field_type != .list) return error.NotAList;
    const source = resolved.source orelse return error.NotPresent;
    const text = try rootText(&snapshot, ctx, ref.document);
    var edit = switch (change) {
        .remove => |index| try data.splice.removeItem(ctx.gpa, text, source, index),
        .move => |move| try data.splice.moveItem(ctx.gpa, text, source, move.from, move.to),
    };
    defer edit.deinit(ctx.gpa);
    const locator: Locator = .{ .document = ref.document, .record = declaration.id, .path = path };
    return commit(ctx, &snapshot, ref.document, edit, locator, locator, diags);
}

pub fn undo(ctx: Context, expected_revision: u64, diags: *Diagnostics) Error!Result {
    try ctx.begin(expected_revision);
    if (ctx.state.history.undo.items.len == 0) return error.HistoryEmpty;
    const entry = ctx.state.history.undo.items[ctx.state.history.undo.items.len - 1];
    return replay(ctx, entry, false, diags);
}

pub fn redo(ctx: Context, expected_revision: u64, diags: *Diagnostics) Error!Result {
    try ctx.begin(expected_revision);
    if (ctx.state.history.redo.items.len == 0) return error.HistoryEmpty;
    const entry = ctx.state.history.redo.items[ctx.state.history.redo.items.len - 1];
    return replay(ctx, entry, true, diags);
}

fn replay(ctx: Context, entry: Entry, forward: bool, diags: *Diagnostics) Error!Result {
    const document = documentFor(ctx, entry.document) catch |err| return err;
    if (!document.editable) return error.ReadOnlyDocument;
    const expected = if (forward) entry.before else entry.after;
    const replacement = if (forward) entry.after else entry.before;
    const end = @as(usize, entry.start) + expected.len;
    if (end > document.bytes.len or !std.mem.eql(u8, document.bytes[entry.start..end], expected)) return error.SourceInvalid;

    const edit: data.splice.Edit = .{ .start = entry.start, .end = @intCast(end), .text = replacement };
    const candidate = try data.splice.apply(ctx.gpa, document.bytes, &.{edit}, ctx.limits.content);
    errdefer ctx.gpa.free(candidate);
    try checkCandidateSize(ctx, entry.document, candidate.len, ctx.state.history.retained_bytes, document.bytes.len);

    const candidate_diags = diags;
    var parsed = parseDocument(ctx.gpa, ctx.documents, ctx.namespace(), ctx.limits.content, entry.document, candidate, candidate_diags) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ContentInvalid => return error.SourceInvalid,
    };
    defer parsed.deinit(ctx.gpa);
    if ((try validateDocument(ctx.gpa, &parsed, &ctx.state.registry, ctx.limits.content, candidate_diags)) == .invalid) return error.SourceInvalid;

    if (forward) {
        try ctx.state.history.undo.ensureUnusedCapacity(ctx.gpa, 1);
    } else {
        try ctx.state.history.redo.ensureUnusedCapacity(ctx.gpa, 1);
    }

    const old = document.bytes;
    document.bytes = candidate;
    ctx.gpa.free(old);
    const moved = if (forward)
        ctx.state.history.redo.pop() orelse unreachable
    else
        ctx.state.history.undo.pop() orelse unreachable;
    if (forward)
        ctx.state.history.undo.appendAssumeCapacity(moved)
    else
        ctx.state.history.redo.appendAssumeCapacity(moved);
    ctx.state.revision += 1;
    const selection = if (forward) moved.after_selection.view() else moved.before_selection.view();
    return .{ .revision = ctx.state.revision, .selection = selection };
}

// ---------------------------------------------------------------------------
// Candidate installation and history
// ---------------------------------------------------------------------------

fn commit(
    ctx: Context,
    snapshot: *Snapshot,
    document_index: u32,
    edit: data.splice.Edit,
    before_selection: Locator,
    after_selection: Locator,
    diags: *Diagnostics,
) Error!Result {
    if (edit.start == edit.end and edit.text.len == 0) return error.NoChange;
    const document = &ctx.documents[document_index];
    const candidate = try data.splice.apply(ctx.gpa, document.bytes, &.{edit}, ctx.limits.content);
    errdefer ctx.gpa.free(candidate);

    var parsed = parseDocument(ctx.gpa, ctx.documents, ctx.namespace(), ctx.limits.content, document_index, candidate, diags) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ContentInvalid => return error.SourceInvalid,
    };
    defer parsed.deinit(ctx.gpa);
    if ((try validateDocument(ctx.gpa, &parsed, &ctx.state.registry, ctx.limits.content, diags)) == .invalid) return error.SourceInvalid;
    try validateUniqueCandidate(ctx, snapshot, document_index, &parsed, diags);

    var entry = try Entry.init(ctx.gpa, document_index, edit.start, document.bytes[edit.start..edit.end], edit.text, before_selection, after_selection);
    errdefer entry.deinit(ctx.gpa);
    const projected_history = try ctx.state.history.projectedAfterPush(ctx.limits, entry.cost());
    try checkCandidateSize(ctx, document_index, candidate.len, projected_history, document.bytes.len + edit.text.len);
    try ctx.state.history.undo.ensureUnusedCapacity(ctx.gpa, 1);

    const old = document.bytes;
    document.bytes = candidate;
    ctx.gpa.free(old);
    ctx.state.history.pushPrepared(ctx.gpa, ctx.limits, entry);
    ctx.state.revision += 1;
    const selection = ctx.state.history.undo.items[ctx.state.history.undo.items.len - 1].after_selection.view();
    return .{ .revision = ctx.state.revision, .selection = selection };
}

fn checkCandidateSize(ctx: Context, document_index: u32, candidate_len: usize, history_bytes: usize, peak_extra: usize) Error!void {
    if (candidate_len > ctx.limits.max_source_bytes) return error.SourceTooLarge;
    var current_total: usize = candidate_len;
    var retained_total: usize = candidate_len + ctx.documents[document_index].baseline.len;
    for (ctx.documents, 0..) |document, i| {
        if (i == document_index) continue;
        current_total = std.math.add(usize, current_total, document.bytes.len) catch return error.DocumentBudget;
        retained_total = std.math.add(usize, retained_total, document.bytes.len + document.baseline.len) catch return error.DocumentBudget;
    }
    if (current_total > ctx.limits.max_total_source_bytes) return error.SourceTooLarge;
    retained_total = std.math.add(usize, retained_total, history_bytes) catch return error.DocumentBudget;
    if (retained_total > ctx.limits.max_document_bytes) return error.DocumentBudget;
    // Candidate validation happens before the old draft and the operation's emitted bytes
    // can be released. Count that real peak too; a budget which covered only the state
    // after commit would still permit an edit to exceed it while being checked.
    const peak = std.math.add(usize, retained_total, peak_extra) catch return error.DocumentBudget;
    if (peak > ctx.limits.max_document_bytes) return error.DocumentBudget;
}

const OwnedLocator = struct {
    document: u32,
    record: ?ContentId,
    path: []Selector,

    fn init(gpa: Allocator, source: Locator) Allocator.Error!OwnedLocator {
        return .{ .document = source.document, .record = source.record, .path = try gpa.dupe(Selector, source.path) };
    }

    fn deinit(self: *OwnedLocator, gpa: Allocator) void {
        gpa.free(self.path);
        self.* = undefined;
    }

    fn view(self: *const OwnedLocator) Locator {
        return .{ .document = self.document, .record = self.record, .path = self.path };
    }
};

const Entry = struct {
    document: u32,
    start: u32,
    before: []u8,
    after: []u8,
    before_selection: OwnedLocator,
    after_selection: OwnedLocator,

    fn init(gpa: Allocator, document: u32, start: u32, before: []const u8, after: []const u8, before_selection: Locator, after_selection: Locator) Allocator.Error!Entry {
        const before_copy = try gpa.dupe(u8, before);
        errdefer gpa.free(before_copy);
        const after_copy = try gpa.dupe(u8, after);
        errdefer gpa.free(after_copy);
        var before_locator = try OwnedLocator.init(gpa, before_selection);
        errdefer before_locator.deinit(gpa);
        var after_locator = try OwnedLocator.init(gpa, after_selection);
        errdefer after_locator.deinit(gpa);
        return .{
            .document = document,
            .start = start,
            .before = before_copy,
            .after = after_copy,
            .before_selection = before_locator,
            .after_selection = after_locator,
        };
    }

    fn cost(self: Entry) usize {
        return self.before.len + self.after.len +
            self.before_selection.path.len * @sizeOf(Selector) +
            self.after_selection.path.len * @sizeOf(Selector);
    }

    fn deinit(self: *Entry, gpa: Allocator) void {
        gpa.free(self.before);
        gpa.free(self.after);
        self.before_selection.deinit(gpa);
        self.after_selection.deinit(gpa);
        self.* = undefined;
    }
};

pub const History = struct {
    undo: std.ArrayList(Entry) = .empty,
    redo: std.ArrayList(Entry) = .empty,
    retained_bytes: usize = 0,
    /// Visible state: at least one complete command was evicted to stay within bounds.
    truncated: bool = false,

    fn deinit(self: *History, gpa: Allocator) void {
        for (self.undo.items) |*entry| entry.deinit(gpa);
        for (self.redo.items) |*entry| entry.deinit(gpa);
        self.undo.deinit(gpa);
        self.redo.deinit(gpa);
        self.* = undefined;
    }

    pub fn clear(self: *History, gpa: Allocator) void {
        for (self.undo.items) |*entry| entry.deinit(gpa);
        for (self.redo.items) |*entry| entry.deinit(gpa);
        self.undo.clearRetainingCapacity();
        self.redo.clearRetainingCapacity();
        self.retained_bytes = 0;
        self.truncated = false;
    }

    fn projectedAfterPush(self: *const History, limits: Limits, cost: usize) Error!usize {
        if (limits.max_history_commands == 0 or cost > limits.max_history_bytes) return error.HistoryLimit;
        var bytes = self.retained_bytes;
        for (self.redo.items) |entry| bytes -= entry.cost();
        var count = self.undo.items.len;
        var first: usize = 0;
        while (count + 1 > limits.max_history_commands or bytes + cost > limits.max_history_bytes) {
            if (first >= self.undo.items.len) return error.HistoryLimit;
            bytes -= self.undo.items[first].cost();
            first += 1;
            count -= 1;
        }
        return bytes + cost;
    }

    /// No allocation: the caller reserved one undo slot after all fallible work passed.
    fn pushPrepared(self: *History, gpa: Allocator, limits: Limits, entry: Entry) void {
        for (self.redo.items) |*redo_entry| {
            self.retained_bytes -= redo_entry.cost();
            redo_entry.deinit(gpa);
        }
        self.redo.clearRetainingCapacity();

        while (self.undo.items.len + 1 > limits.max_history_commands or self.retained_bytes + entry.cost() > limits.max_history_bytes) {
            var oldest = self.undo.orderedRemove(0);
            self.retained_bytes -= oldest.cost();
            oldest.deinit(gpa);
            self.truncated = true;
        }
        self.retained_bytes += entry.cost();
        self.undo.appendAssumeCapacity(entry);
    }
};

// ---------------------------------------------------------------------------
// Parsing, source lookup and exact typed nodes
// ---------------------------------------------------------------------------

const Snapshot = struct {
    ctx: Context,
    parsed: []?data.Document,
    spellings: data.emit.Spellings = .empty,

    fn init(ctx: Context) Error!Snapshot {
        const parsed = try ctx.gpa.alloc(?data.Document, ctx.documents.len);
        @memset(parsed, null);
        var self: Snapshot = .{ .ctx = ctx, .parsed = parsed };
        errdefer self.deinit();

        for (ctx.documents, 0..) |document, i| {
            if (!document.parseable) continue;
            var scratch_diags = Diagnostics.init(ctx.gpa, ctx.limits.content);
            defer scratch_diags.deinit(ctx.gpa);
            var parsed_doc = parseDocument(ctx.gpa, ctx.documents, ctx.namespace(), ctx.limits.content, @intCast(i), null, &scratch_diags) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ContentInvalid => return error.SourceInvalid,
            };
            errdefer parsed_doc.deinit(ctx.gpa);
            var it = parsed_doc.strings.iterator();
            while (it.next()) |entry| try self.putSpelling(entry.value_ptr.*);
            self.parsed[i] = parsed_doc;
        }

        // Recoverable spellings in a compiled dependency are its package, schema and record
        // names. An ID field whose target is not among these remains deliberately
        // unspellable and an override refuses it rather than manufacturing source text.
        for (ctx.dependencies.items()) |*package| {
            try self.putSpelling(package.name());
            for (package.reader.schema_names) |name| try self.putSpelling(name);
            var index: u32 = 0;
            while (package.reader.record(index)) |record| : (index += 1) try self.putSpelling(record.name);
        }
        return self;
    }

    fn deinit(self: *Snapshot) void {
        self.spellings.deinit(self.ctx.gpa);
        for (self.parsed) |*slot| if (slot.*) |*doc| doc.deinit(self.ctx.gpa);
        self.ctx.gpa.free(self.parsed);
        self.* = undefined;
    }

    fn addSpelling(self: *Snapshot, text: []const u8) Error!void {
        _ = try data.emit.checkSpelling(&self.spellings, text);
        try self.putSpelling(text);
    }

    fn putSpelling(self: *Snapshot, text: []const u8) Error!void {
        const id = data.contentId(text) catch return error.InvalidId;
        if (self.spellings.get(id.hash)) |known| {
            if (!std.mem.eql(u8, known, text)) return error.IdCollision;
            return;
        }
        try self.spellings.put(self.ctx.gpa, id.hash, text);
    }
};

const Resolver = struct {
    arena: Allocator,
    documents: []const Document,
    override_document: ?u32,
    override_bytes: ?[]const u8,

    fn interface(self: *Resolver) data.parser.Resolver {
        return .{ .ctx = self, .resolveFn = resolve };
    }

    fn resolve(raw: *anyopaque, importer: []const u8, requested: []const u8) data.parser.Resolution {
        const self: *Resolver = @ptrCast(@alignCast(raw));
        const dir = std.fs.path.dirnamePosix(importer) orelse "";
        const joined = if (dir.len == 0)
            self.arena.dupe(u8, requested) catch return .not_found
        else
            std.fmt.allocPrint(self.arena, "{s}/{s}", .{ dir, requested }) catch return .not_found;
        const canonical = (compiler.normalizePackagePath(self.arena, joined) catch return .not_found) orelse return .outside_package;
        for (self.documents, 0..) |document, i| {
            if (!std.mem.eql(u8, document.path, canonical)) continue;
            const bytes = if (self.override_document != null and self.override_document.? == i)
                self.override_bytes.?
            else
                document.bytes;
            return .{ .found = .{ .name = document.path, .bytes = bytes } };
        }
        return .not_found;
    }
};

fn parseDocument(
    gpa: Allocator,
    documents: []const Document,
    namespace: []const u8,
    limits: data.Limits,
    document_index: u32,
    override_bytes: ?[]const u8,
    diags: *Diagnostics,
) data.parser.Error!data.Document {
    if (document_index >= documents.len) return error.ContentInvalid;
    var scratch: core.Arena = .init(gpa);
    defer scratch.deinit();
    var resolver: Resolver = .{
        .arena = scratch.allocator(),
        .documents = documents,
        .override_document = if (override_bytes != null) document_index else null,
        .override_bytes = override_bytes,
    };
    const document = documents[document_index];
    // A caller may retain diagnostics from a previous operation. The parser's `failed`
    // bit means *this parse* failed, so it receives a fresh collector and its bounded
    // result is copied out afterwards; an old incomplete-draft diagnostic must not make a
    // later valid command look syntactically invalid.
    var parse_diags = Diagnostics.init(gpa, limits);
    defer parse_diags.deinit(gpa);
    var parsed = data.parser.parse(gpa, document.path, override_bytes orelse document.bytes, .{
        .namespace = namespace,
        .limits = limits,
        .resolver = resolver.interface(),
        .spans = true,
    }, &parse_diags) catch |err| {
        try appendDiagnostics(gpa, diags, &parse_diags);
        return err;
    };
    errdefer parsed.deinit(gpa);
    try appendDiagnostics(gpa, diags, &parse_diags);
    return parsed;
}

fn appendDiagnostics(gpa: Allocator, destination: *Diagnostics, source: *const Diagnostics) Allocator.Error!void {
    for (source.items.items) |diagnostic| try destination.add(gpa, diagnostic);
    destination.suppressed +|= source.suppressed;
    destination.failed = destination.failed or source.failed;
}

fn namespaceOf(package_name: ?[]const u8) []const u8 {
    const name = package_name orelse return "package";
    const colon = std.mem.indexOfScalar(u8, name, ':') orelse return "package";
    return name[0..colon];
}

fn isLocal(record: data.parser.RecordDecl) bool {
    return record.source != null and record.source.?.span.file == 0;
}

fn localRecord(document: *const data.Document, index: u32) ?*const data.parser.RecordDecl {
    if (index >= document.records.len) return null;
    const record = &document.records[index];
    return if (isLocal(record.*)) record else null;
}

fn recordIn(snapshot: *const Snapshot, ref: RecordRef) Error!*const data.parser.RecordDecl {
    if (ref.document >= snapshot.parsed.len) return error.InvalidDocument;
    const parsed = if (snapshot.parsed[ref.document]) |*doc| doc else return error.ReadOnlyDocument;
    const record = localRecord(parsed, ref.record) orelse return error.InvalidRecord;
    if (record.kind != .define) return error.InvalidRecord;
    return record;
}

fn rootText(snapshot: *const Snapshot, ctx: Context, document_index: u32) Error!data.splice.Text {
    if (document_index >= snapshot.parsed.len) return error.InvalidDocument;
    const parsed = if (snapshot.parsed[document_index]) |*doc| doc else return error.ReadOnlyDocument;
    return data.splice.Text.of(parsed, 0, ctx.documents[document_index].bytes);
}

fn documentFor(ctx: Context, index: u32) Error!*Document {
    if (index >= ctx.documents.len) return error.InvalidDocument;
    return &ctx.documents[index];
}

fn requireEditable(ctx: Context, index: u32) Error!void {
    const document = try documentFor(ctx, index);
    if (!document.editable) return error.ReadOnlyDocument;
}

const SeenRecord = struct {
    document: u32,
    record: u32,
    text: []const u8,
};

fn ensureUnique(snapshot: *const Snapshot, excluded: ?RecordRef, id: ContentId, text: []const u8) Error!void {
    for (snapshot.parsed, 0..) |*slot, document_index| {
        const document = if (slot.*) |*doc| doc else continue;
        for (document.records, 0..) |record, record_index| {
            if (!isLocal(record)) continue;
            if (excluded) |skip| if (skip.document == document_index and skip.record == record_index) continue;
            if (!record.id.eql(id)) continue;
            _ = text;
            return error.DuplicateRecord;
        }
    }
}

fn validateUniqueCandidate(ctx: Context, snapshot: *const Snapshot, candidate_index: u32, candidate: *const data.Document, diags: *Diagnostics) Error!void {
    var seen: std.AutoHashMapUnmanaged(u64, []const u8) = .empty;
    defer seen.deinit(ctx.gpa);
    for (snapshot.parsed, 0..) |*slot, document_index| {
        if (document_index == candidate_index) continue;
        const document = if (slot.*) |*doc| doc else continue;
        for (document.records) |record| {
            if (!isLocal(record)) continue;
            try seen.put(ctx.gpa, record.id.hash, record.text);
        }
    }
    for (candidate.records) |record| {
        if (!isLocal(record)) continue;
        if (seen.get(record.id.hash)) |other| {
            try diags.addFmt(ctx.gpa, .err, record.origin.location(), record.origin.length, record.origin.line_text, "'{s}' conflicts with existing local definition '{s}'", .{ record.text, other });
            return error.DuplicateRecord;
        }
        try seen.put(ctx.gpa, record.id.hash, record.text);
    }
}

fn schemaName(reader: *const data.fpk.Reader, id: data.SchemaId) ?[]const u8 {
    for (reader.schemas, reader.schema_names) |schema, name| if (schema.id.eql(id)) return name;
    return null;
}

const FieldContainer = struct {
    schema_fields: []const Field,
    sources: []const data.parser.FieldSource,
    body: data.parser.Span,
    record_values: ?[]const data.parser.FieldDecl = null,
    nested_values: ?[]const NamedValue = null,

    fn valueAt(self: FieldContainer, index: usize) Value {
        if (self.record_values) |values| return values[index].value;
        return self.nested_values.?[index].value;
    }

    fn nameAt(self: FieldContainer, index: usize) []const u8 {
        if (self.record_values) |values| return values[index].name;
        return self.nested_values.?[index].name;
    }

    fn count(self: FieldContainer) usize {
        if (self.record_values) |values| return values.len;
        return self.nested_values.?.len;
    }
};

const ListContainer = struct {
    elem: FieldType,
    values: []const Value,
    sources: []const data.parser.ValueSource,
};

const Cursor = union(enum) {
    fields: FieldContainer,
    list: ListContainer,
};

const Resolved = struct {
    field_type: FieldType,
    value: ?Value,
    source: ?data.parser.ValueSource,
    declared_field: ?Field = null,
    parent_fields: ?FieldContainer = null,
    source_index: ?usize = null,
};

fn resolveNode(record: data.parser.RecordDecl, schema: Schema, path: []const Selector) Error!Resolved {
    if (path.len == 0) return error.InvalidPath;
    const source = record.source orelse return error.InvalidRecord;
    var cursor: Cursor = .{ .fields = .{
        .schema_fields = schema.fields,
        .sources = source.fields,
        .body = source.body orelse return error.InvalidRecord,
        .record_values = record.fields,
    } };

    for (path, 0..) |selector, depth| {
        const last = depth + 1 == path.len;
        const resolved: Resolved = switch (cursor) {
            .fields => |fields| blk: {
                const field_index = switch (selector) {
                    .field => |index| index,
                    .item => return error.InvalidPath,
                };
                if (field_index >= fields.schema_fields.len) return error.InvalidPath;
                const field = fields.schema_fields[field_index];
                var source_index: ?usize = null;
                for (0..fields.count()) |i| {
                    if (std.mem.eql(u8, fields.nameAt(i), field.name)) {
                        source_index = i;
                        break;
                    }
                }
                break :blk .{
                    .field_type = field.type,
                    .value = if (source_index) |i| fields.valueAt(i) else null,
                    .source = if (source_index) |i| fields.sources[i].value else null,
                    .declared_field = field,
                    .parent_fields = fields,
                    .source_index = source_index,
                };
            },
            .list => |list| blk: {
                const item_index = switch (selector) {
                    .item => |index| index,
                    .field => return error.InvalidPath,
                };
                if (item_index >= list.values.len or item_index >= list.sources.len) return error.InvalidPath;
                break :blk .{
                    .field_type = list.elem,
                    .value = list.values[item_index],
                    .source = list.sources[item_index],
                };
            },
        };
        if (last) return resolved;
        const value = resolved.value orelse return error.NotPresent;
        const value_source = resolved.source orelse return error.InvalidPath;
        cursor = switch (resolved.field_type) {
            .nested => |fields| .{ .fields = .{
                .schema_fields = fields,
                .sources = value_source.fields,
                .body = value_source.span,
                .nested_values = value.nested,
            } },
            .list => |elem| .{ .list = .{
                .elem = elem.*,
                .values = value.list,
                .sources = value_source.items,
            } },
            else => return error.InvalidPath,
        };
    }
    unreachable;
}

// ---------------------------------------------------------------------------
// Draft validation
// ---------------------------------------------------------------------------

const Validation = enum { valid, incomplete, invalid };

fn mergeValidation(a: Validation, b: Validation) Validation {
    if (a == .invalid or b == .invalid) return .invalid;
    if (a == .incomplete or b == .incomplete) return .incomplete;
    return .valid;
}

fn validateDocument(gpa: Allocator, document: *const data.Document, registry: *data.Registry, limits: data.Limits, diags: *Diagnostics) Allocator.Error!Validation {
    var result: Validation = .valid;
    for (document.records) |record| {
        if (!isLocal(record)) continue;
        if (record.kind != .define) {
            try diags.addFmt(gpa, .err, record.schema_origin.location(), record.schema_origin.length, record.schema_origin.line_text, "only whole record definitions can be edited in M15", .{});
            result = .invalid;
            continue;
        }
        const schema = registry.lookup(record.schema) orelse {
            try diags.addFmt(gpa, .err, record.schema_origin.location(), record.schema_origin.length, record.schema_origin.line_text, "unknown schema '{s}'", .{record.schema_text});
            result = .invalid;
            continue;
        };

        var written = try gpa.alloc(bool, schema.fields.len);
        defer gpa.free(written);
        @memset(written, false);
        for (record.fields) |field| {
            const index = schema.fieldIndex(field.name) orelse {
                try diags.addFmt(gpa, .err, field.name_origin.location(), field.name_origin.length, field.name_origin.line_text, "schema '{s}' has no field '{s}'", .{ record.schema_text, field.name });
                result = .invalid;
                continue;
            };
            if (written[index]) {
                try diags.addFmt(gpa, .err, field.name_origin.location(), field.name_origin.length, field.name_origin.line_text, "field '{s}' is written twice", .{field.name});
                result = .invalid;
                continue;
            }
            written[index] = true;
            result = mergeValidation(result, try validateValue(gpa, schema.fields[index].type, field.value, field.value_origin, field.name, 0, limits, diags));
        }
        for (schema.fields, 0..) |field, i| {
            if (written[i] or field.presence != .required) continue;
            try diags.addFmt(gpa, .err, record.origin.location(), record.origin.length, record.origin.line_text, "'{s}' is an incomplete draft: required field '{s}' is absent", .{ record.text, field.name });
            result = mergeValidation(result, .incomplete);
        }
    }
    return result;
}

fn validateValue(
    gpa: Allocator,
    field_type: FieldType,
    value: Value,
    origin: data.parser.Origin,
    path: []const u8,
    depth: u32,
    limits: data.Limits,
    diags: *Diagnostics,
) Allocator.Error!Validation {
    if (depth >= limits.max_nesting_depth) {
        try diags.addFmt(gpa, .err, origin.location(), origin.length, origin.line_text, "field '{s}' is nested too deeply", .{path});
        return .invalid;
    }
    switch (field_type) {
        .list => |elem| {
            if (value != .list) return wrongValue(gpa, origin, path, field_type, diags);
            if (value.list.len > limits.max_list_elements) {
                try diags.addFmt(gpa, .err, origin.location(), origin.length, origin.line_text, "field '{s}' has too many list elements", .{path});
                return .invalid;
            }
            var result: Validation = .valid;
            for (value.list) |item| result = mergeValidation(result, try validateValue(gpa, elem.*, item, origin, path, depth + 1, limits, diags));
            return result;
        },
        .nested => |fields| {
            if (value != .nested) return wrongValue(gpa, origin, path, field_type, diags);
            var result: Validation = .valid;
            const written = try gpa.alloc(bool, fields.len);
            defer gpa.free(written);
            @memset(written, false);
            for (value.nested) |named| {
                var field_index: ?usize = null;
                for (fields, 0..) |field, i| if (std.mem.eql(u8, field.name, named.name)) {
                    field_index = i;
                    break;
                };
                const index = field_index orelse {
                    try diags.addFmt(gpa, .err, origin.location(), origin.length, origin.line_text, "field '{s}' has no nested field '{s}'", .{ path, named.name });
                    result = .invalid;
                    continue;
                };
                if (written[index]) {
                    try diags.addFmt(gpa, .err, origin.location(), origin.length, origin.line_text, "field '{s}' writes nested field '{s}' twice", .{ path, named.name });
                    result = .invalid;
                    continue;
                }
                written[index] = true;
                result = mergeValidation(result, try validateValue(gpa, fields[index].type, named.value, origin, named.name, depth + 1, limits, diags));
            }
            for (fields, 0..) |field, i| {
                if (written[i] or field.presence != .required) continue;
                try diags.addFmt(gpa, .err, origin.location(), origin.length, origin.line_text, "field '{s}' is an incomplete draft: required nested field '{s}' is absent", .{ path, field.name });
                result = mergeValidation(result, .incomplete);
            }
            return result;
        },
        else => {
            data.schema.checkValue(field_type, value, limits, depth) catch |err| {
                try diags.addFmt(gpa, .err, origin.location(), origin.length, origin.line_text, "field '{s}' does not fit {f}: {s}", .{ path, field_type, @errorName(err) });
                return .invalid;
            };
            return .valid;
        },
    }
}

fn wrongValue(gpa: Allocator, origin: data.parser.Origin, path: []const u8, field_type: FieldType, diags: *Diagnostics) Allocator.Error!Validation {
    try diags.addFmt(gpa, .err, origin.location(), origin.length, origin.line_text, "field '{s}' does not have declared type {f}", .{ path, field_type });
    return .invalid;
}
