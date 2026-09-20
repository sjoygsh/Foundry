//! The values that cross for v4's authoring surface, and nothing that uses them.
//!
//! The same rule the rest of the boundary obeys: nothing crosses whose layout Foundry does
//! not state (`public-abi.md` §5). Every struct here is `extern`, every width is deliberate,
//! every reserved byte is written as zero, and `agreement.c` states the same numbers in C.
//!
//! **Numbers are text here, and that is the decision** (`editor.md` §9). The simulation side
//! of this ABI reads an `f32` because that is what a sprite's position is; an *author* typing
//! `9007199254740993` into a `u64` field is not describing a sprite, and a boundary that sent
//! it through a float would silently change it. So an authoring scalar crosses as its
//! canonical decimal spelling plus the field type the schema declares, and the exact value
//! survives in both directions. It is not a second number convention for the engine — no
//! v1–v3 call changes — it is the one representation that cannot lose an author's input.
//!
//! **Unset, default and present are three states, not two.** `FoundryAuthorNodeInfo` carries
//! `authored` and `presence` separately for that reason: a field the source does not write,
//! whose schema has a default, is neither "missing" nor "set to the default", and a form that
//! could not tell them apart would write defaults into files nobody asked it to.
//!
//! Design: `docs/design/editor.md` §9.

const std = @import("std");
const data = @import("data");

const types = @import("types.zig");

const Bool = types.Bool;
const ContentId = types.ContentId;
const SchemaId = types.SchemaId;
const Str = types.Str;

// == Enumerations ======================================================================

/// Whether a field must be written, may be, or reads as something when it is not.
///
/// `element` is the fourth because a list element is not a field: it has no declaration of
/// its own, so asking whether it is optional is a question with no answer rather than an
/// answer of "no".
pub const Presence = enum(i32) {
    required = 0,
    optional = 1,
    default = 2,
    element = 3,

    pub fn fromData(presence: ?data.Presence) Presence {
        const p = presence orelse return .element;
        return switch (p) {
            .required => .required,
            .optional => .optional,
            .default => .default,
        };
    }
};

pub const Severity = enum(i32) {
    err = 0,
    warning = 1,
    note = 2,

    pub fn fromData(severity: data.diagnostic.Severity) Severity {
        return switch (severity) {
            .err => .err,
            .warning => .warning,
            .note => .note,
        };
    }
};

/// Which read-only or editable tree a node came from. A client shows a dependency
/// definition differently from its own draft, and the same call answers for both.
pub const NodeRoot = enum(i32) {
    /// A record in one of this workspace's source documents.
    source = 0,
    /// A definition in a host-granted dependency package. Read-only.
    dependency = 1,
    /// A record in the runtime snapshot the last preview activation published. Read-only.
    preview = 2,
    /// A schema's declared default, walked as a value. Read-only.
    default = 3,
};

pub const PreviewOutcome = enum(i32) {
    /// Nothing has been activated in this workspace.
    none = 0,
    /// The loaded content is this build's.
    active = 1,
    /// The last request was declined, and whatever was loaded before still is.
    failed = 2,
};

pub const SaveOutcome = enum(i32) {
    /// The draft already matched the file; nothing was written.
    unchanged = 0,
    published = 1,
    failed = 2,
};

/// Why one file in a Save All was not published. `none` accompanies every outcome that is
/// not a failure, so a client never has to read a stale code.
pub const SaveFailure = enum(i32) {
    none = 0,
    external_change = 1,
    document_budget = 2,
    io_failed = 3,
    out_of_memory = 4,
};

/// What a host-configured destination receives.
pub const ExportKind = enum(i32) {
    /// The compiled package and the assets the compiler produced — `fpack`'s output set.
    compiled = 0,
    /// The complete runtime tree, ordinary assets included.
    runtime = 1,
};

// == Structs ===========================================================================

/// What a workspace is, and what may be done with it right now.
pub const WorkspaceInfo = extern struct {
    revision: u64 = 0,
    /// The package's `namespace:name` from its manifest. Empty when there is no readable
    /// manifest, which is a state rather than a failure: it is where a new package starts.
    package_name: Str = .empty,
    package_version: u32 = 0,
    document_count: u32 = 0,
    dependency_count: u32 = 0,
    build_count: u32 = 0,
    /// Entries in the last operation's diagnostic snapshot, and how many that operation
    /// did not record because its cap was reached.
    diagnostic_count: u32 = 0,
    suppressed_diagnostics: u32 = 0,
    export_count: u32 = 0,
    can_edit: Bool = 0,
    can_save: Bool = 0,
    can_build: Bool = 0,
    can_preview: Bool = 0,
    dirty: Bool = 0,
    externally_changed: Bool = 0,
    can_undo: Bool = 0,
    can_redo: Bool = 0,
    history_truncated: Bool = 0,
    has_manifest: Bool = 0,
    reserved: [10]u8 = @splat(0),
};

/// The bounds this workspace was configured with, so a client can say why something was
/// refused instead of guessing (`editor.md` §4).
pub const Limits = extern struct {
    max_source_bytes: u64 = 0,
    max_total_source_bytes: u64 = 0,
    max_document_bytes: u64 = 0,
    max_history_bytes: u64 = 0,
    max_snapshot_bytes: u64 = 0,
    max_history_commands: u32 = 0,
    max_live_builds: u32 = 0,
    max_sources: u32 = 0,
    max_diagnostics: u32 = 0,
    max_nesting_depth: u32 = 0,
    max_list_elements: u32 = 0,
};

pub const DocumentInfo = extern struct {
    /// The document's package-relative name, which is also its identity to the compiler.
    path: Str = .empty,
    source_bytes: u64 = 0,
    index: u32 = 0,
    reserved0: u32 = 0,
    dirty: Bool = 0,
    /// False for a document created in memory whose create-if-absent Save has not run.
    on_disk: Bool = 0,
    externally_changed: Bool = 0,
    /// The syntax parsed under this workspace's namespace and imports.
    parseable: Bool = 0,
    /// Typed commands may touch it. An incomplete draft is still editable; an unknown
    /// schema or an unsupported directive is not.
    editable: Bool = 0,
    reserved: [3]u8 = @splat(0),
};

/// One node of a record, in whichever tree it came from.
pub const NodeInfo = extern struct {
    /// The field's declared name, or the record's spelling at a root. Empty for a list
    /// element.
    name: Str = .empty,
    /// The record's content id at a root; zero below one.
    id: ContentId = .none,
    /// The record's schema at a root; zero below one.
    schema: SchemaId = .{ .hash = 0 },
    /// `FoundryFieldType`.
    field_type: i32 = 0,
    /// `FoundryAuthorPresence`.
    presence: i32 = 0,
    /// Fields of a nested block, elements of a list, zero for a scalar. A nested block's
    /// count is its schema's even when nothing has been written into it.
    child_count: u32 = 0,
    /// The field index or list position this node has in its parent; zero at a root.
    index: u32 = 0,
    /// `FoundryAuthorNodeRoot`.
    root: i32 = 0,
    /// Which document a source node belongs to, or which dependency package a dependency
    /// node came from. Zero for the other roots.
    container: u32 = 0,
    /// Whether the source or the stored record actually carries this node, as distinct
    /// from the schema having a default for it.
    authored: Bool = 0,
    is_root: Bool = 0,
    is_list: Bool = 0,
    /// False for every read-only root: a command naming such a node is refused.
    writable: Bool = 0,
    /// How many selectors were followed to reach this node. Zero at a root.
    depth: u8 = 0,
    reserved: [3]u8 = @splat(0),
};

/// One node of a schema declaration: a schema, one of its fields, a nested field, or a
/// list's element type.
pub const SchemaNodeInfo = extern struct {
    /// The schema's `namespace:name` at a root, the field's name below one, empty for a
    /// list's element type.
    name: Str = .empty,
    /// The schema's id at a root; zero below one.
    schema: SchemaId = .{ .hash = 0 },
    /// `FoundryFieldType`. At a root this is `FOUNDRY_FIELD_NESTED`, because a record is
    /// laid out exactly like one.
    field_type: i32 = 0,
    /// `FoundryAuthorPresence`.
    presence: i32 = 0,
    child_count: u32 = 0,
    /// The schema version that introduced this field. Zero at a root.
    since: u32 = 0,
    /// The schema's own version at a root. Zero below one.
    version: u32 = 0,
    /// The field index or element position within the parent declaration.
    index: u32 = 0,
    is_root: Bool = 0,
    /// Whether `author_schema_node_default` has a value to hand back.
    has_default: Bool = 0,
    is_list_element: Bool = 0,
    reserved: [5]u8 = @splat(0),
};

/// A scalar crossing in either direction.
///
/// On the way in, `field_type` is what the caller believes the schema declares and is
/// checked against it; `text` carries the spelling and `boolean` the value of a boolean.
/// On the way out, `text` is borrowed and `id` carries the hash even when no spelling could
/// be recovered for it.
pub const Value = extern struct {
    /// `FoundryFieldType`.
    field_type: i32 = 0,
    boolean: Bool = 0,
    reserved: [3]u8 = @splat(0),
    /// The content id of an `id` value. Ignored on the way in, where the spelling is what
    /// a source file has to contain.
    id: ContentId = .none,
    /// Canonical decimal for a number, the bytes themselves for a string, the
    /// `namespace:name` spelling for an id, empty for a boolean and for an empty container.
    text: Str = .empty,
};

/// One host-granted dependency package.
pub const PackageInfo = extern struct {
    name: Str = .empty,
    /// The path the host named it by. Diagnostics only: a path never means identity
    /// (ADR-0021).
    path: Str = .empty,
    id: ContentId = .none,
    version: u32 = 0,
    record_count: u32 = 0,
    index: u32 = 0,
    reserved: u32 = 0,
};

/// What one accepted command did.
pub const Edit = extern struct {
    revision: u64 = 0,
    /// The document the command changed.
    document: types.Document = .none,
    /// Where a client should put the selection afterwards, already re-resolved against the
    /// new revision. Null when the command removed what it was pointing at.
    selection: types.SourceNode = .none,
    record: ContentId = .none,
    has_record: Bool = 0,
    reserved: [7]u8 = @splat(0),
};

pub const SaveResult = extern struct {
    revision: u64 = 0,
    document: types.Document = .none,
    /// `FoundryAuthorSaveOutcome`.
    outcome: i32 = 0,
    /// `FoundryAuthorSaveFailure`.
    failure: i32 = 0,
    /// True when the bytes and the entry naming them were both flushed. False means the
    /// bytes are in place and readable with weaker crash durability — not "failed, retry".
    durable: Bool = 0,
    /// False means the cooperating-writer token could not safely be removed, and a later
    /// save will report `Refused` until its owner recovers it.
    lock_released: Bool = 0,
    reserved: [6]u8 = @splat(0),
};

pub const SaveAll = extern struct {
    revision: u64 = 0,
    entry_count: u32 = 0,
    published_count: u32 = 0,
    lock_released: Bool = 0,
    /// False when the run stopped at a failure. Files already published stay published and
    /// the rest stay dirty: Save All is a prefix, never a transaction (`editor.md` §7).
    complete: Bool = 0,
    reserved: [6]u8 = @splat(0),
};

pub const SaveEntry = extern struct {
    path: Str = .empty,
    document: types.Document = .none,
    outcome: i32 = 0,
    failure: i32 = 0,
    durable: Bool = 0,
    reserved: [7]u8 = @splat(0),
};

/// One entry of the last operation's diagnostic snapshot.
pub const Diagnostic = extern struct {
    /// The workspace revision the operation ran at, so a client can tell a fresh
    /// diagnostic from one it has already shown.
    revision: u64 = 0,
    /// The package-relative source name, or the name of whatever else was being read.
    file: Str = .empty,
    message: Str = .empty,
    /// The offending line, captured when the diagnostic was made.
    source_line: Str = .empty,
    /// The secondary message that explains the first — "the schema is declared over here".
    note: Str = .empty,
    note_file: Str = .empty,
    line: u32 = 0,
    column: u32 = 0,
    /// How many bytes the caret run covers. At least one.
    length: u32 = 0,
    /// `FoundryAuthorSeverity`.
    severity: i32 = 0,
    note_line: u32 = 0,
    note_column: u32 = 0,
    /// How many diagnostics this operation did not record because its cap was reached.
    /// The same number on every entry: it describes the snapshot, not the entry.
    suppressed: u32 = 0,
    has_note: Bool = 0,
    reserved: [3]u8 = @splat(0),
};

pub const BuildInfo = extern struct {
    /// The workspace revision the build was made at.
    revision: u64 = 0,
    package_name: Str = .empty,
    package_bytes: u64 = 0,
    package_version: u32 = 0,
    reserved: u32 = 0,
};

pub const PreviewInfo = extern struct {
    /// The content generation the host published, which is the same number
    /// `content_generation` answers once a preview is active.
    content_generation: u64 = 0,
    /// The workspace revision the previewed build was made at.
    build_revision: u64 = 0,
    build: types.Build = .none,
    /// `FoundryAuthorPreviewOutcome`.
    outcome: i32 = 0,
    /// Whether this host granted preview at all. Editing, saving and building work
    /// without it.
    available: Bool = 0,
    reserved: [3]u8 = @splat(0),
};

/// One destination a host will let a build be written to.
pub const ExportInfo = extern struct {
    name: Str = .empty,
    index: u32 = 0,
    /// `FoundryAuthorExportKind`.
    kind: i32 = 0,
    has_assets: Bool = 0,
    reserved: [7]u8 = @splat(0),
};

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

test "every authoring struct is the size the header states, with nothing implicit in it" {
    // The sizes are here as well as in `agreement.c` for the reason the whole agreement
    // exists: two independent statements of one contract, so a change lands on whoever
    // made it. These also catch a reserved array that no longer absorbs the padding.
    try testing.expectEqual(@as(usize, 72), @sizeOf(WorkspaceInfo));
    try testing.expectEqual(@as(usize, 64), @sizeOf(Limits));
    try testing.expectEqual(@as(usize, 40), @sizeOf(DocumentInfo));
    try testing.expectEqual(@as(usize, 64), @sizeOf(NodeInfo));
    try testing.expectEqual(@as(usize, 56), @sizeOf(SchemaNodeInfo));
    try testing.expectEqual(@as(usize, 32), @sizeOf(Value));
    try testing.expectEqual(@as(usize, 56), @sizeOf(PackageInfo));
    try testing.expectEqual(@as(usize, 40), @sizeOf(Edit));
    try testing.expectEqual(@as(usize, 32), @sizeOf(SaveResult));
    try testing.expectEqual(@as(usize, 24), @sizeOf(SaveAll));
    try testing.expectEqual(@as(usize, 40), @sizeOf(SaveEntry));
    try testing.expectEqual(@as(usize, 120), @sizeOf(Diagnostic));
    try testing.expectEqual(@as(usize, 40), @sizeOf(BuildInfo));
    try testing.expectEqual(@as(usize, 32), @sizeOf(PreviewInfo));
    try testing.expectEqual(@as(usize, 32), @sizeOf(ExportInfo));

    inline for (.{
        WorkspaceInfo, Limits,      DocumentInfo, NodeInfo,    SchemaNodeInfo,
        Value,         PackageInfo, Edit,         SaveResult,  SaveAll,
        SaveEntry,     Diagnostic,  BuildInfo,    PreviewInfo, ExportInfo,
    }) |T| {
        try testing.expectEqual(@as(usize, 8), @alignOf(T));
    }
}

test "the authoring enumerations are the numbers the header states" {
    try testing.expectEqual(@as(i32, 0), @intFromEnum(Presence.required));
    try testing.expectEqual(@as(i32, 3), @intFromEnum(Presence.element));
    try testing.expectEqual(@as(i32, 0), @intFromEnum(Severity.err));
    try testing.expectEqual(@as(i32, 2), @intFromEnum(Severity.note));
    try testing.expectEqual(@as(i32, 0), @intFromEnum(NodeRoot.source));
    try testing.expectEqual(@as(i32, 3), @intFromEnum(NodeRoot.default));
    try testing.expectEqual(@as(i32, 0), @intFromEnum(PreviewOutcome.none));
    try testing.expectEqual(@as(i32, 2), @intFromEnum(PreviewOutcome.failed));
    try testing.expectEqual(@as(i32, 0), @intFromEnum(SaveOutcome.unchanged));
    try testing.expectEqual(@as(i32, 2), @intFromEnum(SaveOutcome.failed));
    try testing.expectEqual(@as(i32, 0), @intFromEnum(SaveFailure.none));
    try testing.expectEqual(@as(i32, 4), @intFromEnum(SaveFailure.out_of_memory));
    try testing.expectEqual(@as(i32, 0), @intFromEnum(ExportKind.compiled));
    try testing.expectEqual(@as(i32, 1), @intFromEnum(ExportKind.runtime));

    // A presence `data` can express and this cannot would be one an editor could not
    // render, so the mapping is total rather than defaulted.
    inline for (@typeInfo(data.Presence).@"union".fields) |f| {
        _ = std.meta.stringToEnum(Presence, f.name) orelse {
            std.debug.print("data.Presence.{s} has no number at the boundary\n", .{f.name});
            return error.TestUnexpectedResult;
        };
    }
    inline for (@typeInfo(data.diagnostic.Severity).@"enum".fields) |f| {
        _ = std.meta.stringToEnum(Severity, f.name) orelse {
            std.debug.print("data.Severity.{s} has no number at the boundary\n", .{f.name});
            return error.TestUnexpectedResult;
        };
    }
}
