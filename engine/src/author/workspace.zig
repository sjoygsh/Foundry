//! A workspace: one granted package directory, open for authoring.
//!
//! **What a session holds while an author works on a package**: the source documents it
//! found, the dependency packages its host granted, what its manifest says it is and needs,
//! and the bounds all of that was read under. Typed commands edit its in-memory documents,
//! with revision checks and bounded undo/redo. Explicit persistence and isolated candidate
//! builds share those documents without turning either into an implicit side effect.
//!
//! **A workspace is a capability, and its root is borrowed.** The host owns the directory
//! and grants it; nothing in a package can name another one, and no call here reaches a
//! path outside what it was given. Reads go through `platform`'s confined, no-follow
//! primitives, which refuse a link rather than follow it at every component of a path — so
//! a source reached through a symlink is not read, and a granted directory cannot be used
//! to read the files beside it.
//!
//! **Refuses before it keeps.** Every bound is enforced as the thing it bounds is taken: a
//! tree with more sources than the walk allows, a source larger than one file may be, or a
//! total larger than a workspace may hold is `error.OverBudget` with a diagnostic naming
//! the limit, and what it would have built is freed on the way out rather than returned
//! half-built. The same is true of a dependency that is not a package.
//!
//! **What is a diagnostic rather than a refusal is deliberate.** An empty directory opens,
//! because that is where a new package starts; a manifest that is not a manifest opens with
//! the diagnostic recorded and no identity, because the file that needs fixing must be
//! reachable by the tool that fixes it (§5, "an externally malformed document remains
//! byte-preserved and diagnostic/read-only"); and a requirement no granted package provides
//! is a diagnostic beside a workspace that still opens, because a missing dependency is
//! something the author is about to write down, not a reason to show them nothing.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const mod = @import("mod");
const platform = @import("platform");

const compiler = @import("compiler.zig");
const build_mod = @import("build.zig");
const dependency = @import("dependency.zig");
const edit = @import("edit.zig");
const save = @import("save.zig");

const Allocator = std.mem.Allocator;
const Diagnostics = data.Diagnostics;
const Os = platform.os.Os;

/// How much of a workspace a session will hold.
///
/// `editor.md` §4's table, where each row is this module's to keep: one source file, all
/// the source files together, and the walk that finds them. The rows that belong to another
/// module are that module's limits, named here so a host configures one object: the parser's
/// `data.Limits` and the dependency reader's own bounds.
///
/// **A host may configure tighter bounds and this never raises one.** A limit silently
/// raised is a limit that is not one, and §4 is explicit that the configured values are
/// reported rather than adjusted. They are public for exactly that reason: a later step
/// publishes them through workspace info.
pub const Limits = struct {
    /// One source file. The same number `compiler.Options` defaults to, because a source
    /// file is one source file whichever way it is read.
    max_source_bytes: usize = 16 * 1024 * 1024,
    /// Every source file together.
    max_total_source_bytes: usize = 64 * 1024 * 1024,
    /// Current drafts, disk baselines and retained history together. Parser allocations
    /// are operation-scoped; this is the persistent editing budget from `editor.md` §4.
    max_document_bytes: usize = 256 * 1024 * 1024,
    /// Complete commands retained for Undo.
    max_history_commands: u32 = 128,
    /// Before/after fragments and their selection locators retained by Undo and Redo.
    max_history_bytes: usize = 64 * 1024 * 1024,
    /// How much of the granted directory discovery may look at.
    walk: compiler.Walk.Limits = .default,
    /// The bounds a document is parsed under — nesting, fields, list lengths, identifier
    /// lengths (`data.Limits`), and the diagnostic cap a workspace operation reports under.
    content: data.Limits = .default,
    /// What the granted dependency packages are read under.
    dependencies: dependency.Limits = .default,
    /// Source, asset and dependency bytes captured for one validation/build operation.
    max_snapshot_bytes: usize = 512 * 1024 * 1024,
    /// Successful candidates retained until a caller releases them.
    max_live_builds: u32 = 2,

    pub const default: Limits = .{};
};

pub const Grants = struct {
    /// Typed in-memory commands and explicit discard/refresh.
    edit: bool = false,
    /// Atomic publication below the source root.
    save: bool = false,
    /// Private candidates below `Options.output_root`.
    build: bool = false,
};

/// What a host grants a workspace, besides the directory itself.
pub const Options = struct {
    /// The `.fpk` files this package is written against, in the order the host means them.
    ///
    /// **Explicit, and never discovered** (§4). The engine does not search for a package: a
    /// dependency nobody granted is unknown rather than found, so a workspace reads the
    /// same set on two machines with the same grant and no ambient mod library can change
    /// what an author is checked against.
    dependencies: []const dependency.Source = &.{},
    /// A separate, existing host-granted directory for private build candidates.
    output_root: ?[]const u8 = null,
    grants: Grants = .{},
    limits: Limits = .default,
};

pub const Error = error{
    /// A granted file is not a package, or is a package this build cannot read.
    ContentInvalid,
    /// Something could not be read. Not a content problem, and reported apart from one.
    IoFailed,
    /// A configured limit was exceeded. Nothing about the content is wrong — there is too
    /// much of it to look at — and the difference decides whether an author edits a file or
    /// moves a tree.
    OverBudget,
    /// The source/output/dependency roots overlap, or build authority has no output root.
    InvalidGrant,
} || Allocator.Error;

pub const RefreshError = error{
    StaleRevision,
    RevisionExhausted,
    InvalidDocument,
    WriteNotGranted,
    DirtyDocument,
    NoChange,
    DocumentBudget,
    IoFailed,
} || Allocator.Error;

/// One source file, open in a workspace.
pub const Document = edit.Document;

/// A granted package directory, open for authoring.
pub const Workspace = struct {
    gpa: Allocator,
    /// Everything owned that outlives one call: discovered paths and requirement names. The
    /// documents' bytes are not here, because each one is freed by name as it is replaced.
    arena: core.Arena,
    os: *Os,
    /// The granted directory, **borrowed**: the host owns it and this does not copy it, as
    /// a compile borrows the directory it is handed.
    root: []const u8,
    output_root: ?[]const u8,
    grants: Grants,
    limits: Limits,
    /// Every source file, in discovery order — sorted by path, so the same tree gives the
    /// same list on every machine (I9).
    documents: []Document = &.{},
    /// The granted dependency packages, read and checked. Empty is a valid set: a package
    /// with no dependencies has none.
    dependencies: dependency.Set,
    /// What the manifest says this package is, or null when there is no readable manifest.
    ///
    /// **Null is a state, not a failure** (§4): a directory with no manifest is where a new
    /// package starts, and one whose manifest is malformed opens with its diagnostic
    /// recorded so that the file needing the fix is the one the author can reach.
    identity: ?compiler.Identity = null,
    /// What the manifest says must load before this package, in declaration order.
    requires: []const compiler.SourceRequirement = &.{},
    /// Schemas, revision and bounded command history. It owns no source paths or files;
    /// those remain visibly workspace state above.
    editing: edit.State,
    builds: build_mod.State = .{},
    build_sequence: u64 = 0,

    /// Opens `root`: reads the manifest, loads the granted dependencies, discovers the
    /// sources and reads every one, and reports what the manifest requires that was not
    /// granted.
    pub fn open(
        gpa: Allocator,
        os: *Os,
        root: []const u8,
        options: Options,
        diags: *Diagnostics,
    ) Error!Workspace {
        var self: Workspace = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .os = os,
            .root = root,
            .output_root = options.output_root,
            .grants = options.grants,
            .limits = options.limits,
            .dependencies = .init(gpa),
            .editing = .init(gpa, options.limits.content),
        };
        errdefer self.deinit();

        try self.validateGrants(options.dependencies, diags);
        try self.readManifest(diags);
        self.dependencies = try dependency.Set.load(gpa, os, options.dependencies, options.limits.dependencies, diags);
        try self.readDocuments(diags);
        try self.reportUnsatisfied(diags);
        try self.editing.prepare(gpa, self.documents, &self.dependencies, if (self.identity) |identity| identity.name else null, self.editLimits(), diags);

        return self;
    }

    pub fn deinit(self: *Workspace) void {
        self.builds.deinit(self.gpa, self.os, self.output_root);
        for (self.documents) |*document| document.deinit(self.gpa);
        self.gpa.free(self.documents);
        if (self.identity) |identity| self.gpa.free(identity.name);
        self.editing.deinit(self.gpa);
        self.dependencies.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn revision(self: *const Workspace) u64 {
        return self.editing.revision;
    }

    pub fn dirty(self: *const Workspace) bool {
        for (self.documents) |document| if (document.dirty()) return true;
        return false;
    }

    pub fn historyTruncated(self: *const Workspace) bool {
        return self.editing.history.truncated;
    }

    pub fn canUndo(self: *const Workspace) bool {
        return self.editing.history.undo.items.len != 0;
    }

    pub fn canRedo(self: *const Workspace) bool {
        return self.editing.history.redo.items.len != 0;
    }

    pub fn schemas(self: *Workspace) *data.Registry {
        return &self.editing.registry;
    }

    pub fn inspectRecord(self: *Workspace, ref: edit.RecordRef, diags: *Diagnostics) edit.Error!edit.Inspection {
        return edit.inspect(self.editContext(), ref, diags);
    }

    /// A parse of one whole document, for a reader walking more than one of its records.
    pub fn openDocument(self: *Workspace, document: u32, diags: *Diagnostics) edit.Error!edit.Inspection {
        return edit.openDocument(self.editContext(), document, diags);
    }

    /// Every schema an author may write in this package, by the spelling that goes in the
    /// file, sorted and without duplicates.
    ///
    /// A registry holds hashes, because nothing that *reads* content needs a name. A form
    /// offering "create a record" does, and this is where the spellings come from: the
    /// engine's own list, every dependency's own table, and every schema this package
    /// declares. Built once at open and kept in the workspace arena, because the set
    /// cannot change while the workspace is open — M15 inspects schema declarations and
    /// does not edit them (`editor.md` §5).
    pub fn schemaNames(self: *const Workspace) []const []const u8 {
        return self.editing.schema_names;
    }

    /// The spelling of one schema, or null for a hash this workspace has no word for.
    pub fn schemaNameOf(self: *const Workspace, schema_id: data.SchemaId) ?[]const u8 {
        for (self.editing.schema_names) |name| {
            if (data.SchemaId.fromStringUnchecked(name).eql(schema_id)) return name;
        }
        return null;
    }

    pub fn createRecord(self: *Workspace, expected_revision: u64, document: u32, schema: []const u8, id: []const u8, diags: *Diagnostics) edit.Error!edit.Result {
        if (!self.grants.edit) return error.WriteNotGranted;
        return edit.createRecord(try self.beginEdit(diags), expected_revision, document, schema, id, diags);
    }

    pub fn duplicateRecord(self: *Workspace, expected_revision: u64, source: edit.RecordRef, destination: u32, id: []const u8, diags: *Diagnostics) edit.Error!edit.Result {
        if (!self.grants.edit) return error.WriteNotGranted;
        return edit.duplicateRecord(try self.beginEdit(diags), expected_revision, source, destination, id, diags);
    }

    pub fn createOverride(self: *Workspace, expected_revision: u64, destination: u32, source: edit.DependencyRecordRef, diags: *Diagnostics) edit.Error!edit.Result {
        if (!self.grants.edit) return error.WriteNotGranted;
        return edit.createOverride(try self.beginEdit(diags), expected_revision, destination, source, diags);
    }

    pub fn deleteRecord(self: *Workspace, expected_revision: u64, ref: edit.RecordRef, diags: *Diagnostics) edit.Error!edit.Result {
        if (!self.grants.edit) return error.WriteNotGranted;
        return edit.deleteRecord(try self.beginEdit(diags), expected_revision, ref, diags);
    }

    pub fn setValue(self: *Workspace, expected_revision: u64, ref: edit.RecordRef, path: []const edit.Selector, value: edit.TypedValue, diags: *Diagnostics) edit.Error!edit.Result {
        if (!self.grants.edit) return error.WriteNotGranted;
        return edit.setValue(try self.beginEdit(diags), expected_revision, ref, path, value, diags);
    }

    pub fn unsetField(self: *Workspace, expected_revision: u64, ref: edit.RecordRef, path: []const edit.Selector, diags: *Diagnostics) edit.Error!edit.Result {
        if (!self.grants.edit) return error.WriteNotGranted;
        return edit.unsetField(try self.beginEdit(diags), expected_revision, ref, path, diags);
    }

    pub fn insertListItem(self: *Workspace, expected_revision: u64, ref: edit.RecordRef, path: []const edit.Selector, index: u32, value: edit.TypedValue, diags: *Diagnostics) edit.Error!edit.Result {
        if (!self.grants.edit) return error.WriteNotGranted;
        return edit.insertListItem(try self.beginEdit(diags), expected_revision, ref, path, index, value, diags);
    }

    pub fn removeListItem(self: *Workspace, expected_revision: u64, ref: edit.RecordRef, path: []const edit.Selector, index: u32, diags: *Diagnostics) edit.Error!edit.Result {
        if (!self.grants.edit) return error.WriteNotGranted;
        return edit.removeListItem(try self.beginEdit(diags), expected_revision, ref, path, index, diags);
    }

    pub fn moveListItem(self: *Workspace, expected_revision: u64, ref: edit.RecordRef, path: []const edit.Selector, from: u32, to: u32, diags: *Diagnostics) edit.Error!edit.Result {
        if (!self.grants.edit) return error.WriteNotGranted;
        return edit.moveListItem(try self.beginEdit(diags), expected_revision, ref, path, from, to, diags);
    }

    pub fn undo(self: *Workspace, expected_revision: u64, diags: *Diagnostics) edit.Error!edit.Result {
        if (!self.grants.edit) return error.WriteNotGranted;
        return edit.undo(try self.beginEdit(diags), expected_revision, diags);
    }

    pub fn redo(self: *Workspace, expected_revision: u64, diags: *Diagnostics) edit.Error!edit.Result {
        if (!self.grants.edit) return error.WriteNotGranted;
        return edit.redo(try self.beginEdit(diags), expected_revision, diags);
    }

    pub fn createDocument(self: *Workspace, expected_revision: u64, path: []const u8) edit.Error!u32 {
        if (!self.grants.edit) return error.WriteNotGranted;
        if (expected_revision != self.editing.revision) return error.StaleRevision;
        if (self.editing.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        if (self.documents.len >= self.limits.walk.max_sources) return error.SourceTooLarge;
        if (!validDocumentPath(path)) return error.InvalidDocumentName;
        for (self.documents) |document| if (std.mem.eql(u8, document.path, path)) return error.DuplicateDocument;
        var parent = self.os.listDirConfined(self.gpa, self.root, std.fs.path.dirnamePosix(path) orelse ".") catch
            return error.InvalidDocumentName;
        parent.deinit();
        if (self.os.statFileConfined(self.root, path)) |_| return error.DuplicateDocument else |err| switch (err) {
            error.FileNotFound => {},
            else => return error.InvalidDocumentName,
        }

        const owned_path = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned_path);
        const bytes = try self.gpa.alloc(u8, 0);
        errdefer self.gpa.free(bytes);
        const baseline = try self.gpa.alloc(u8, 0);
        errdefer self.gpa.free(baseline);
        const next = try self.gpa.alloc(Document, self.documents.len + 1);
        errdefer self.gpa.free(next);
        @memcpy(next[0..self.documents.len], self.documents);
        next[self.documents.len] = .{
            .path = owned_path,
            .owns_path = true,
            .bytes = bytes,
            .baseline = baseline,
            .disk = .{ .size = 0, .kind = .file, .modified_ns = 0 },
            .on_disk = false,
            .parseable = true,
            .editable = true,
        };
        self.gpa.free(self.documents);
        self.documents = next;
        self.editing.revision += 1;
        return @intCast(self.documents.len - 1);
    }

    /// Replaces a draft with its last-read/saved bytes. This is the explicit destructive
    /// half of conflict recovery: refreshing a dirty draft is refused until its caller has
    /// deliberately discarded it.
    pub fn discardDocument(self: *Workspace, expected_revision: u64, document: u32, diags: *Diagnostics) RefreshError!u64 {
        try self.beginRefresh(expected_revision, document);
        const current = &self.documents[document];
        if (!current.dirty()) return error.NoChange;
        return self.installDocumentVersion(document, current.baseline, current.baseline, current.disk, current.on_disk, diags);
    }

    /// Accepts the current disk file as both draft and baseline. It never overwrites a dirty
    /// draft: the caller must make the destructive discard a separate, revisioned action.
    pub fn refreshDocument(self: *Workspace, expected_revision: u64, document: u32, diags: *Diagnostics) RefreshError!u64 {
        try self.beginRefresh(expected_revision, document);
        const current = &self.documents[document];
        if (current.dirty()) return error.DirtyDocument;

        const read = self.os.readFileConfined(self.gpa, self.root, current.path, self.limits.max_source_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileTooLarge => return error.DocumentBudget,
            else => {
                try diags.addFmt(self.gpa, .err, .whole(current.path), 1, "", "could not be refreshed from disk: {s}", .{@errorName(err)});
                return error.IoFailed;
            },
        };
        defer self.gpa.free(read.bytes);
        if (std.mem.eql(u8, read.bytes, current.baseline) and current.on_disk and !current.externally_changed)
            return error.NoChange;
        return self.installDocumentVersion(document, read.bytes, read.bytes, read.info, true, diags);
    }

    pub fn saveDocument(self: *Workspace, expected_revision: u64, document: u32, diags: *Diagnostics) save.Error!save.Result {
        return save.saveOne(self.saveContext(), expected_revision, document, diags);
    }

    pub fn saveAll(self: *Workspace, expected_revision: u64, diags: *Diagnostics) save.Error!save.AllResult {
        return save.saveAll(self.saveContext(), expected_revision, diags);
    }

    pub fn validate(self: *Workspace, expected_revision: u64, diags: *Diagnostics) build_mod.Error!void {
        return build_mod.validate(self.buildContext(), expected_revision, diags);
    }

    pub fn build(self: *Workspace, expected_revision: u64, diags: *Diagnostics) build_mod.Error!build_mod.Handle {
        return build_mod.build(self.buildContext(), expected_revision, diags);
    }

    pub fn buildInfo(self: *Workspace, handle: build_mod.Handle) build_mod.Error!build_mod.Info {
        return build_mod.info(self.buildContext(), handle);
    }

    pub fn releaseBuild(self: *Workspace, handle: build_mod.Handle, diags: *Diagnostics) build_mod.Error!void {
        return build_mod.release(self.buildContext(), handle, diags);
    }

    pub fn buildCount(self: *const Workspace) u32 {
        return self.builds.count();
    }

    fn beginRefresh(self: *Workspace, expected_revision: u64, document: u32) RefreshError!void {
        if (!self.grants.edit) return error.WriteNotGranted;
        if (expected_revision != self.editing.revision) return error.StaleRevision;
        if (self.editing.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        if (document >= self.documents.len) return error.InvalidDocument;
    }

    fn installDocumentVersion(
        self: *Workspace,
        document_index: u32,
        bytes: []const u8,
        baseline: []const u8,
        disk: platform.os.FileInfo,
        on_disk: bool,
        diags: *Diagnostics,
    ) RefreshError!u64 {
        if (bytes.len > self.limits.max_source_bytes or baseline.len > self.limits.max_source_bytes)
            return error.DocumentBudget;

        var total_source: usize = 0;
        var persistent: usize = 0;
        for (self.documents, 0..) |document, i| {
            const draft_len = if (i == document_index) bytes.len else document.bytes.len;
            const baseline_len = if (i == document_index) baseline.len else document.baseline.len;
            total_source = std.math.add(usize, total_source, draft_len) catch return error.DocumentBudget;
            persistent = std.math.add(usize, persistent, draft_len) catch return error.DocumentBudget;
            persistent = std.math.add(usize, persistent, baseline_len) catch return error.DocumentBudget;
        }
        if (total_source > self.limits.max_total_source_bytes or persistent > self.limits.max_document_bytes)
            return error.DocumentBudget;

        const next_bytes = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(next_bytes);
        const next_baseline = try self.gpa.dupe(u8, baseline);
        errdefer self.gpa.free(next_baseline);
        const staged = try self.gpa.dupe(Document, self.documents);
        defer self.gpa.free(staged);
        staged[document_index].bytes = next_bytes;
        staged[document_index].baseline = next_baseline;
        staged[document_index].disk = disk;
        staged[document_index].on_disk = on_disk;
        staged[document_index].externally_changed = false;

        var next_editing = edit.State.init(self.gpa, self.limits.content);
        errdefer next_editing.deinit(self.gpa);
        next_editing.revision = self.editing.revision + 1;
        try next_editing.prepare(self.gpa, staged, &self.dependencies, if (self.identity) |identity| identity.name else null, self.editLimits(), diags);

        const target = &self.documents[document_index];
        self.gpa.free(target.bytes);
        self.gpa.free(target.baseline);
        target.bytes = next_bytes;
        target.baseline = next_baseline;
        target.disk = disk;
        target.on_disk = on_disk;
        target.externally_changed = false;
        for (self.documents, staged) |*document, classified| {
            document.parseable = classified.parseable;
            document.editable = classified.editable;
        }
        self.editing.deinit(self.gpa);
        self.editing = next_editing;
        return self.editing.revision;
    }

    /// What this package calls itself *now*: the draft manifest if there is one, and the
    /// file that was on disk when the workspace opened otherwise.
    pub fn packageName(self: *const Workspace) ?[]const u8 {
        if (self.editing.package_name) |name| return name;
        return if (self.identity) |identity| identity.name else null;
    }

    pub fn packageVersion(self: *const Workspace) u32 {
        if (self.editing.package_name != null) return self.editing.package_version;
        return if (self.identity) |identity| identity.version else 0;
    }

    fn editLimits(self: *const Workspace) edit.Limits {
        return .{
            .max_source_bytes = self.limits.max_source_bytes,
            .max_total_source_bytes = self.limits.max_total_source_bytes,
            .max_document_bytes = self.limits.max_document_bytes,
            .max_history_commands = self.limits.max_history_commands,
            .max_history_bytes = self.limits.max_history_bytes,
            .content = self.limits.content,
        };
    }

    /// The context a command runs in, after making sure the parse it is about to edit was
    /// made under the package's *current* namespace.
    ///
    /// Done before the command rather than after the one that changed it, so an
    /// allocation failure here leaves the workspace exactly as it was.
    fn beginEdit(self: *Workspace, diags: *Diagnostics) Allocator.Error!edit.Context {
        const wanted = edit.namespaceOf(self.packageName());
        if (!std.mem.eql(u8, wanted, self.editing.namespace)) {
            try self.editing.reprepare(self.gpa, self.documents, &self.dependencies, self.packageName(), self.editLimits(), diags);
        }
        return self.editContext();
    }

    fn editContext(self: *Workspace) edit.Context {
        return .{
            .gpa = self.gpa,
            .documents = self.documents,
            .dependencies = &self.dependencies,
            .state = &self.editing,
            .package_name = self.packageName(),
            .limits = self.editLimits(),
        };
    }

    fn saveContext(self: *Workspace) save.Context {
        return .{
            .gpa = self.gpa,
            .os = self.os,
            .root = self.root,
            .documents = self.documents,
            .state = &self.editing,
            .max_source_bytes = self.limits.max_source_bytes,
            .max_document_bytes = self.limits.max_document_bytes,
            .write_granted = self.grants.save,
        };
    }

    fn buildContext(self: *Workspace) build_mod.Context {
        return .{
            .gpa = self.gpa,
            .os = self.os,
            .source_root = self.root,
            .output_root = self.output_root,
            .documents = self.documents,
            .dependencies = &self.dependencies,
            .revision = self.editing.revision,
            .build_granted = self.grants.build,
            .write_granted = self.grants.save,
            .limits = .{
                .max_source_bytes = self.limits.max_source_bytes,
                .max_snapshot_bytes = self.limits.max_snapshot_bytes,
                .max_live_builds = self.limits.max_live_builds,
                .walk = self.limits.walk,
                .content = self.limits.content,
                .dependencies = self.limits.dependencies,
            },
            .state = &self.builds,
            .sequence = &self.build_sequence,
        };
    }

    fn validateGrants(self: *Workspace, dependency_sources: []const dependency.Source, diags: *Diagnostics) Error!void {
        if (self.grants.build and self.output_root == null) {
            try diags.addFmt(self.gpa, .err, .whole("<workspace>"), 1, "", "build authority requires a separate output root", .{});
            return error.InvalidGrant;
        }
        const output = self.output_root orelse return;
        if (try rootsOverlap(self.gpa, self.os, self.root, output)) {
            try diags.addFmt(self.gpa, .err, .whole(output), 1, "", "the build output root overlaps the source root", .{});
            return error.InvalidGrant;
        }
        for (dependency_sources) |source| {
            const package_root = std.fs.path.dirname(source.path) orelse ".";
            if (try rootsOverlap(self.gpa, self.os, package_root, output)) {
                try diags.addFmt(self.gpa, .err, .whole(output), 1, "", "the build output root overlaps a dependency package root", .{});
                return error.InvalidGrant;
            }
            if (source.assets_root) |assets_root| if (try rootsOverlap(self.gpa, self.os, assets_root, output)) {
                try diags.addFmt(self.gpa, .err, .whole(output), 1, "", "the build output root overlaps a dependency asset root", .{});
                return error.InvalidGrant;
            };
        }
    }

    /// Reads `mod.fdt` if it is there, and takes the package's identity and requirements.
    fn readManifest(self: *Workspace, diags: *Diagnostics) Error!void {
        // **Asked before it is read**, because `readSelf` — which a *compile* uses, and
        // which is right to insist — makes an absent manifest a diagnostic, while an empty
        // directory is a valid workspace. It is one stat, and it is confined like every
        // other read here, so a link is refused rather than followed by it too.
        _ = self.os.statFileConfined(self.root, compiler.manifest_file) catch |err| switch (err) {
            error.FileNotFound => return,
            error.OutOfMemory => return error.OutOfMemory,
            // There, and not readable as a file: `readSelf` says so in its own words.
            else => {},
        };

        const self_read = compiler.readSelf(self.gpa, self.arena.allocator(), self.os, self.root, .{
            .limits = self.limits.content,
            .max_source_bytes = self.limits.max_source_bytes,
            .walk = self.limits.walk,
        }, diags) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Opened anyway, with the diagnostic kept. §5's malformed document is
            // diagnostic and read-only rather than invisible, and a workspace that refused
            // to open would hide the file behind the tool that is supposed to fix it.
            error.ContentInvalid, error.IoFailed => return,
            error.OverBudget => return error.OverBudget,
        };
        self.identity = self_read.identity;
        self.requires = self_read.requires;
    }

    /// Discovers the package's sources and reads every one.
    fn readDocuments(self: *Workspace, diags: *Diagnostics) Error!void {
        // The walk owns its lists and its paths live in this workspace's arena, which is
        // what outlives it. Order is the walk's and never the filesystem's (I9).
        var walk = try compiler.Walk.run(self.gpa, self.arena.allocator(), self.os, self.root, self.limits.walk, diags);
        defer walk.deinit(self.gpa);

        const documents = try self.gpa.alloc(Document, walk.sources.items.len);
        errdefer self.gpa.free(documents);

        // Only what has been kept: the array is one allocation and the bytes are many, so
        // an error part-way through frees the files already read rather than all of them.
        var kept: usize = 0;
        errdefer for (documents[0..kept]) |*document| document.deinit(self.gpa);

        var total: usize = 0;
        for (walk.sources.items) |path| {
            const read = self.os.readFileConfined(self.gpa, self.root, path, self.limits.max_source_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FileTooLarge => {
                    try diags.addFmt(self.gpa, .err, .whole(path), 1, "", "is larger than the {d} bytes one source file may be", .{self.limits.max_source_bytes});
                    return error.OverBudget;
                },
                else => {
                    // **Refused rather than followed**, which is what the read being
                    // confined means: a source reached through a link, a path that climbs,
                    // or something that is not a regular file cannot be read into a
                    // workspace, and saying which file and why is the whole message.
                    try diags.addFmt(self.gpa, .err, .whole(path), 1, "", "could not be read as a source file: {s}", .{@errorName(err)});
                    return error.IoFailed;
                },
            };

            total += read.bytes.len;
            if (total > self.limits.max_total_source_bytes) {
                // Freed before the message, so that a failed diagnostic allocation cannot
                // leak the bytes it was about to report on.
                self.gpa.free(read.bytes);
                try diags.addFmt(self.gpa, .err, .whole(path), 1, "", "leaves the workspace's sources totalling more than {d} bytes", .{self.limits.max_total_source_bytes});
                return error.OverBudget;
            }
            if (total > self.limits.max_document_bytes / 2) {
                self.gpa.free(read.bytes);
                try diags.addFmt(self.gpa, .err, .whole(path), 1, "", "leaves the workspace's drafts and disk baselines totalling more than the {d}-byte document budget", .{self.limits.max_document_bytes});
                return error.OverBudget;
            }

            const baseline = self.gpa.dupe(u8, read.bytes) catch |err| {
                self.gpa.free(read.bytes);
                return err;
            };
            documents[kept] = .{
                .path = path,
                .bytes = read.bytes,
                .baseline = baseline,
                .disk = read.info,
            };
            kept += 1;
        }

        self.documents = documents;
    }

    /// Reports every declared requirement the granted set does not satisfy.
    ///
    /// **A diagnostic, not a refusal** (§4), at severity `error` so that a host which checks
    /// `diags.failed` sees a package that cannot build yet. Naming the version the author
    /// wrote and the version they were granted is the one case where this can say what to
    /// change; naming the package they must ask their host for is the other.
    /// What the manifest says must load before this package, against what was granted.
    ///
    /// An error, and an error for a build-only host as much as for an editor: a build's
    /// last step loads the candidate through `mod`'s ordinary resolution, which refuses a
    /// package whose declared requirement is not there. Reporting it here, at the
    /// manifest line that declares it, is the difference between a diagnostic an author
    /// can act on and one about a file they never wrote.
    fn reportUnsatisfied(self: *const Workspace, diags: *Diagnostics) Error!void {
        const severity: data.diagnostic.Severity = .err;
        for (self.requires) |required| {
            if (self.dependencies.satisfies(required.requirement) != null) continue;

            const range = required.requirement.range;
            const origin = required.origin;
            if (self.dependencies.find(required.requirement.id)) |granted| {
                if (range.max) |max| {
                    try diags.addFmt(self.gpa, severity, origin.location(), origin.length, origin.line_text, "'requires' names '{s}' at version {d} to {d}, and the granted package is version {d}", .{ required.name, range.min, max, granted.version() });
                } else {
                    try diags.addFmt(self.gpa, severity, origin.location(), origin.length, origin.line_text, "'requires' names '{s}' at version {d} or later, and the granted package is version {d}", .{ required.name, range.min, granted.version() });
                }
                continue;
            }

            try diags.addFmt(self.gpa, severity, origin.location(), origin.length, origin.line_text, "'requires' names '{s}', which no granted dependency provides: a dependency is named by the host, never found by the engine", .{required.name});
        }
    }
};

fn validDocumentPath(path: []const u8) bool {
    if (!platform.os.isSafeRelativePath(path)) return false;
    if (!std.mem.endsWith(u8, path, "." ++ compiler.source_extension)) return false;
    const leaf = std.fs.path.basename(path);
    if (leaf.len > platform.os.max_replaceable_name) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        // The shared compiler deliberately ignores dot-prefixed entries. Letting a
        // workspace create one would make Save succeed and Build report an inventory
        // mismatch for a file its own compiler cannot see.
        if (component.len == 0 or component[0] == '.') return false;
    }
    return true;
}

fn rootsOverlap(gpa: Allocator, os: *Os, a: []const u8, b: []const u8) Error!bool {
    const left = os.canonicalPathAlloc(gpa, a) catch return error.InvalidGrant;
    defer gpa.free(left);
    const right = os.canonicalPathAlloc(gpa, b) catch return error.InvalidGrant;
    defer gpa.free(right);
    return pathContains(left, right) or pathContains(right, left);
}

fn pathContains(parent: []const u8, child: []const u8) bool {
    const equal = if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(parent, child)
    else
        std.mem.eql(u8, parent, child);
    if (equal) return true;
    const prefix = if (builtin.os.tag == .windows)
        std.ascii.startsWithIgnoreCase(child, parent)
    else
        std.mem.startsWith(u8, child, parent);
    if (!prefix) return false;
    if (parent.len == 0 or child.len <= parent.len) return false;
    const last = parent[parent.len - 1];
    return std.fs.path.isSep(last) or std.fs.path.isSep(child[parent.len]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");

const Fixture = struct {
    tmp: std.testing.TmpDir,
    os: *Os,
    root: []const u8,
    root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    /// Paths this fixture allocated, so that a test does not have to free them by hand.
    owned: std.ArrayList([]const u8) = .empty,

    fn init() !*Fixture {
        const gpa = testing.allocator;
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);
        self.* = .{
            .tmp = testing.tmpDir(.{}),
            .os = try Os.init(gpa, .{ .app_name = "foundry-author-test" }),
            .root = "",
        };
        const n = try self.tmp.dir.realPath(testing.io, &self.root_buf);
        self.root = self.root_buf[0..n];
        return self;
    }

    fn deinit(self: *Fixture) void {
        const gpa = testing.allocator;
        for (self.owned.items) |path| gpa.free(path);
        self.owned.deinit(gpa);
        self.os.deinit();
        self.tmp.cleanup();
        gpa.destroy(self);
    }

    /// An absolute path under the fixture, remembered so the test need not free it.
    fn at(self: *Fixture, rel: []const u8) ![]const u8 {
        const gpa = testing.allocator;
        const path = try platform.os.joinPath(gpa, &.{ self.root, rel });
        errdefer gpa.free(path);
        try self.owned.append(gpa, path);
        return path;
    }

    fn write(self: *Fixture, rel: []const u8, contents: []const u8) !void {
        const gpa = testing.allocator;
        const path = try platform.os.joinPath(gpa, &.{ self.root, rel });
        defer gpa.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.os.createDirPath(parent);
        try self.os.writeFile(path, contents);
    }

    /// The manifest of the package under test, which is always `pkg/mod.fdt`: a workspace's
    /// root is one directory, and a test that wrote its manifest at the fixture's root
    /// would be granting a directory it did not mean to.
    fn manifest(self: *Fixture, text: []const u8) !void {
        try self.write("pkg/mod.fdt", text);
    }

    /// Compiles a dependency package and writes the `.fpk` beside it, which is what a
    /// granted dependency file is.
    fn pack(self: *Fixture, name: []const u8, manifest_text: []const u8, source: []const u8) ![]const u8 {
        const gpa = testing.allocator;
        const dir = try std.fmt.allocPrint(gpa, "{s}/deps/{s}", .{ self.root, name });
        defer gpa.free(dir);
        const text = try std.fmt.allocPrint(gpa, "{s}\n{s}\n", .{ manifest_text, source });
        defer gpa.free(text);
        const text_path = try std.fmt.allocPrint(gpa, "deps/{s}/mod.fdt", .{name});
        defer gpa.free(text_path);
        try self.write(text_path, text);

        var registry = data.Registry.init(gpa, .default);
        defer registry.deinit(gpa);
        var diags = Diagnostics.init(gpa, .default);
        defer diags.deinit(gpa);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);

        const identity = try compiler.compile(gpa, self.os, dir, .{}, &registry, &diags, &bytes);
        defer gpa.free(identity.name);
        if (diags.failed) {
            for (diags.items.items) |d| std.debug.print("fixture: {s}\n", .{d.message});
            return error.FixtureFailed;
        }

        const rel = try std.fmt.allocPrint(gpa, "deps/{s}.fpk", .{name});
        defer gpa.free(rel);
        const path = try self.at(rel);
        try self.os.writeFile(path, bytes.items);
        return path;
    }
};

fn documentNamed(workspace: *const Workspace, path: []const u8) u32 {
    for (workspace.documents, 0..) |document, i| {
        if (std.mem.eql(u8, document.path, path)) return @intCast(i);
    }
    unreachable;
}

test "sources are discovered in path order, and the manifest is one of them" {
    const f = try Fixture.init();
    defer f.deinit();

    // Written in the order a filesystem is free to return them in, and one of them nested,
    // so that a walk which kept the listing's order or walked breadth-first would fail here.
    try f.write("pkg/z/last.fdt", "foundry:thing demo:last { }\n");
    try f.write("pkg/b.fdt", "foundry:thing demo:b { }\n");
    try f.write("pkg/a.fdt", "@schema foundry:thing { }\nfoundry:thing demo:a { }\n");
    try f.write("pkg/notes.txt", "not content\n");
    try f.write("pkg/.hidden/ignored.fdt", "foundry:thing demo:hidden { }\n");
    try f.manifest("foundry:mod demo:root { name \"Root\" version 1 license \"MIT\" }\n");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{}, &diags);
    defer workspace.deinit();

    try testing.expectEqual(@as(usize, 4), workspace.documents.len);
    try testing.expectEqualStrings("a.fdt", workspace.documents[0].path);
    try testing.expectEqualStrings("b.fdt", workspace.documents[1].path);
    try testing.expectEqualStrings("mod.fdt", workspace.documents[2].path);
    try testing.expectEqualStrings("z/last.fdt", workspace.documents[3].path);
    try testing.expectEqualStrings("@schema foundry:thing { }\nfoundry:thing demo:a { }\n", workspace.documents[0].bytes);

    // The baseline is the same read that produced the bytes, not a second stat of a file
    // that may have changed in between.
    try testing.expectEqual(@as(u64, workspace.documents[0].bytes.len), workspace.documents[0].disk.size);
    try testing.expect(workspace.documents[0].disk.modified_ns != 0);

    try testing.expectEqualStrings("demo:root", workspace.identity.?.name);
    try testing.expectEqual(@as(u32, 1), workspace.identity.?.version);
    try testing.expectEqual(@as(usize, 0), workspace.requires.len);
    try testing.expectEqual(@as(u32, 0), workspace.dependencies.count());
    try testing.expect(!diags.failed);
}

test "an empty directory is a workspace with nothing in it, not a failure" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.os.createDirPath(try f.at("pkg"));

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{}, &diags);
    defer workspace.deinit();

    // §4: this is where a new package starts, and a session that refused to open it could
    // not offer to create the manifest that would make it one.
    try testing.expectEqual(@as(usize, 0), workspace.documents.len);
    try testing.expect(workspace.identity == null);
    try testing.expectEqual(@as(usize, 0), workspace.requires.len);
    try testing.expect(!diags.failed);
}

test "a manifest written in the workspace names the package before anything is saved" {
    // An editor creates `mod.fdt` and then fills it in. `open` read the manifest from disk
    // and there was none, so without reading the draft the package would have no name for
    // the whole session — and a bare id in it would resolve under the wrong namespace.
    const f = try Fixture.init();
    defer f.deinit();
    try f.write("pkg/records.fdt", "@schema item { name string }\n");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);
    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{ .grants = .{ .edit = true } }, &diags);
    defer workspace.deinit();
    try testing.expect(workspace.packageName() == null);

    const document = try workspace.createDocument(workspace.revision(), "mod.fdt");
    var result = try workspace.createRecord(workspace.revision(), document, "foundry:mod", "demo:root", &diags);
    try testing.expect(workspace.packageName() != null);
    try testing.expectEqualStrings("demo:root", workspace.packageName().?);
    try testing.expectEqual(@as(u32, 0), workspace.packageVersion());

    const ref: edit.RecordRef = .{ .document = document, .record = 0 };
    const version_field = mod.schemas.manifest.fieldIndex(mod.schemas.version_field).?;
    result = try workspace.setValue(result.revision, ref, &.{.{ .field = version_field }}, .{ .value = .{ .int = 3 } }, &diags);
    try testing.expectEqual(@as(u32, 3), workspace.packageVersion());

    // And undoing it takes the name back, because the record it came from is gone again.
    _ = try workspace.undo(result.revision, &diags);
    try testing.expectEqual(@as(u32, 0), workspace.packageVersion());
}

test "creating a manifest re-reads every schema under the package's new namespace" {
    // A bare `@schema item` means `package:item` in a workspace with no manifest and
    // `demo:item` in one called `demo:root`. Every document was parsed under the first, so
    // without rebuilding, the next command cannot find a schema plainly declared in it.
    const f = try Fixture.init();
    defer f.deinit();
    try f.write("pkg/records.fdt", "@schema item { name string }\n");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);
    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{ .grants = .{ .edit = true } }, &diags);
    defer workspace.deinit();

    const document = try workspace.createDocument(workspace.revision(), "mod.fdt");
    var result = try workspace.createRecord(workspace.revision(), document, "foundry:mod", "demo:root", &diags);
    const ref: edit.RecordRef = .{ .document = document, .record = 0 };
    const version_field = mod.schemas.manifest.fieldIndex(mod.schemas.version_field).?;
    result = try workspace.setValue(result.revision, ref, &.{.{ .field = version_field }}, .{ .value = .{ .int = 1 } }, &diags);

    // The schema is now published, and usable, under the package's namespace.
    const names = workspace.editing.schema_names;
    var found = false;
    for (names) |name| {
        if (std.mem.eql(u8, name, "demo:item")) found = true;
        try testing.expect(!std.mem.eql(u8, name, "package:item"));
    }
    try testing.expect(found);
    _ = try workspace.createRecord(workspace.revision(), 1, "demo:item", "demo:one", &diags);
}

test "a manifest gives the workspace its identity and its requirements" {
    const f = try Fixture.init();
    defer f.deinit();

    try f.manifest(
        \\foundry:mod demo:root {
        \\  name "Root" version 1 license "MIT"
        \\  requires [ { id demo:core min 2 max 4 } { id demo:torch } ]
        \\}
        \\
    );

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{
        .dependencies = &.{
            .{ .path = try f.pack("core", "foundry:mod demo:core { name \"Core\" version 3 license \"MIT\" }", "") },
            .{ .path = try f.pack("torch", "foundry:mod demo:torch { name \"Torch\" version 1 license \"MIT\" }", "") },
        },
    }, &diags);
    defer workspace.deinit();

    try testing.expectEqualStrings("demo:root", workspace.identity.?.name);
    try testing.expectEqual(@as(u32, 2), workspace.dependencies.count());

    try testing.expectEqual(@as(usize, 2), workspace.requires.len);
    try testing.expectEqualStrings("demo:core", workspace.requires[0].name);
    try testing.expectEqual(core.ContentId.fromString("demo:core"), workspace.requires[0].requirement.id);
    try testing.expectEqual(@as(u32, 2), workspace.requires[0].requirement.range.min);
    try testing.expectEqual(@as(?u32, 4), workspace.requires[0].requirement.range.max);
    // A requirement that leaves `min` out means any version, exactly as it does in a
    // compiled package, where the schema's own default supplies the 1.
    try testing.expectEqualStrings("demo:torch", workspace.requires[1].name);
    try testing.expectEqual(@as(u32, 1), workspace.requires[1].requirement.range.min);
    try testing.expectEqual(@as(?u32, null), workspace.requires[1].requirement.range.max);

    // The origin is the field an author wrote, so a caller's message points at the line
    // rather than at the file.
    try testing.expectEqualStrings("mod.fdt", workspace.requires[0].origin.file);
    try testing.expectEqual(@as(u32, 3), workspace.requires[0].origin.line);
    try testing.expectEqual(@as(u32, 8), workspace.requires[0].origin.length);
    try testing.expect(!diags.failed);
}

test "a requirement nothing granted provides is reported, and the workspace still opens" {
    const f = try Fixture.init();
    defer f.deinit();

    try f.write("pkg/a.fdt", "@schema foundry:thing { }\nfoundry:thing demo:a { }\n");
    try f.manifest("foundry:mod demo:root { name \"Root\" version 1 license \"MIT\" requires [ { id demo:core } ] }\n");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{}, &diags);
    defer workspace.deinit();

    // The point of the diagnostic rather than a refusal: the author can still see every
    // document, including the manifest they are about to add the dependency to.
    try testing.expectEqual(@as(usize, 2), workspace.documents.len);
    try testing.expect(diags.failed);
    try testing.expectEqual(@as(usize, 1), diags.items.items.len);
    try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "demo:core") != null);
    try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "never found by the engine") != null);
    try testing.expectEqualStrings("mod.fdt", diags.items.items[0].location.file);
}

test "a requirement the granted package is too old for names both versions" {
    const f = try Fixture.init();
    defer f.deinit();

    try f.manifest(
        \\foundry:mod demo:root {
        \\  name "Root" version 1 license "MIT"
        \\  requires [ { id demo:core min 5 } { id demo:core min 1 max 2 } ]
        \\}
        \\
    );

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{
        .dependencies = &.{.{ .path = try f.pack("core", "foundry:mod demo:core { name \"Core\" version 3 license \"MIT\" }", "") }},
    }, &diags);
    defer workspace.deinit();

    try testing.expect(diags.failed);
    try testing.expectEqual(@as(usize, 2), diags.items.items.len);
    try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "at version 5 or later, and the granted package is version 3") != null);
    try testing.expect(std.mem.indexOf(u8, diags.items.items[1].message, "at version 1 to 2, and the granted package is version 3") != null);
    // A satisfied requirement is not reported, so the workspace's own dependency on the
    // package it was granted is silent.
    try testing.expect(std.mem.indexOf(u8, diags.items.items[1].message, "demo:torch") == null);
}

test "a workspace's configured budgets refuse rather than truncate" {
    const gpa = testing.allocator;

    // More sources than the walk allows.
    {
        const f = try Fixture.init();
        defer f.deinit();
        try f.write("pkg/a.fdt", "foundry:thing demo:a { }\n");
        try f.write("pkg/b.fdt", "foundry:thing demo:b { }\n");
        try f.write("pkg/c.fdt", "foundry:thing demo:c { }\n");

        var diags = Diagnostics.init(gpa, .default);
        defer diags.deinit(gpa);

        try testing.expectError(error.OverBudget, Workspace.open(gpa, f.os, try f.at("pkg"), .{
            .limits = .{ .walk = .{ .max_sources = 2 } },
        }, &diags));
        try testing.expect(diags.failed);
        try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "one source file more than the 2 a package may contain") != null);
    }

    // One file larger than a source file may be.
    {
        const f = try Fixture.init();
        defer f.deinit();
        try f.write("pkg/a.fdt", "foundry:thing demo:a { }\n");

        var diags = Diagnostics.init(gpa, .default);
        defer diags.deinit(gpa);

        try testing.expectError(error.OverBudget, Workspace.open(gpa, f.os, try f.at("pkg"), .{
            .limits = .{ .max_source_bytes = 8 },
        }, &diags));
        try testing.expect(diags.failed);
        try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "larger than the 8 bytes") != null);
    }

    // Every source together larger than a workspace may hold, which the per-file bound
    // above does not catch: two files, each well inside it.
    {
        const f = try Fixture.init();
        defer f.deinit();
        try f.write("pkg/a.fdt", "foundry:thing demo:a { }\n");
        try f.write("pkg/b.fdt", "foundry:thing demo:b { }\n");

        var diags = Diagnostics.init(gpa, .default);
        defer diags.deinit(gpa);

        try testing.expectError(error.OverBudget, Workspace.open(gpa, f.os, try f.at("pkg"), .{
            .limits = .{ .max_total_source_bytes = 30 },
        }, &diags));
        try testing.expect(diags.failed);
        try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "totalling more than 30 bytes") != null);
    }

    // More entries than the walk may look at, none of them sources: the sources bound
    // alone would walk a tree of anything else without end.
    {
        const f = try Fixture.init();
        defer f.deinit();
        try f.write("pkg/a.txt", "");
        try f.write("pkg/b.txt", "");
        try f.write("pkg/c.txt", "");

        var diags = Diagnostics.init(gpa, .default);
        defer diags.deinit(gpa);

        try testing.expectError(error.OverBudget, Workspace.open(gpa, f.os, try f.at("pkg"), .{
            .limits = .{ .walk = .{ .max_entries = 2 } },
        }, &diags));
        try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "more than 2 entries") != null);
        // Named by where it is in the package, not by where the host keeps the package.
        try testing.expectEqualStrings(".", diags.items.items[0].location.file);
    }

    // A source deeper than the walk may descend.
    {
        const f = try Fixture.init();
        defer f.deinit();
        try f.write("pkg/one/two/three/deep.fdt", "foundry:thing demo:deep { }\n");

        var diags = Diagnostics.init(gpa, .default);
        defer diags.deinit(gpa);

        try testing.expectError(error.OverBudget, Workspace.open(gpa, f.os, try f.at("pkg"), .{
            .limits = .{ .walk = .{ .max_depth = 2 } },
        }, &diags));
        try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "deeper than 2 directories") != null);
        try testing.expectEqualStrings("one/two/three", diags.items.items[0].location.file);
    }
}

test "a source reached through a symlink is not read, and a link out is not followed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const f = try Fixture.init();
    defer f.deinit();

    // The granted directory is `pkg`, and both of these point out of it: one file and one
    // directory, because a walk that followed either would be reading content the host did
    // not grant.
    try f.write("pkg/inside.fdt", "@schema foundry:thing { }\nfoundry:thing demo:inside { }\n");
    try f.write("outside.fdt", "foundry:thing demo:outside { }\n");
    try f.write("elsewhere/other.fdt", "foundry:thing demo:other { }\n");
    try f.tmp.dir.symLink(testing.io, try f.at("outside.fdt"), "pkg/linked.fdt", .{});
    try f.tmp.dir.symLink(testing.io, try f.at("elsewhere"), "pkg/linked_dir", .{ .is_directory = true });

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{}, &diags);
    defer workspace.deinit();

    // One document, and it is the one that is really there. A link is skipped exactly as
    // the compiler skips it, so the editor's file list and `fpack`'s source list are the
    // same list rather than two answers to one question.
    try testing.expectEqual(@as(usize, 1), workspace.documents.len);
    try testing.expectEqualStrings("inside.fdt", workspace.documents[0].path);
    try testing.expect(!diags.failed);
}

test "a malformed manifest opens, keeps its diagnostic, and hides nothing else" {
    const f = try Fixture.init();
    defer f.deinit();

    const malformed = "this is not a manifest at all\n";
    try f.manifest(malformed);
    try f.write("pkg/a.fdt", "foundry:thing demo:a { }\n");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{}, &diags);
    defer workspace.deinit();

    try testing.expect(workspace.identity == null);
    try testing.expectEqual(@as(usize, 0), workspace.requires.len);
    try testing.expect(diags.failed);

    // §5: byte-preserved and diagnostic. The file is still a document, with the bytes the
    // author wrote in it, which is what makes the diagnostic's caret point at something.
    try testing.expectEqual(@as(usize, 2), workspace.documents.len);
    try testing.expectEqualStrings("a.fdt", workspace.documents[0].path);
    try testing.expectEqualStrings("mod.fdt", workspace.documents[1].path);
    try testing.expectEqualStrings("foundry:thing demo:a { }\n", workspace.documents[0].bytes);
    try testing.expectEqualStrings(malformed, workspace.documents[1].bytes);
}

test "a workspace's granted set is what a compile is handed" {
    const f = try Fixture.init();
    defer f.deinit();

    // A dependency that declares a schema, and a source in the workspace that uses it: the
    // record can only be checked if the granted package's schema reached the registry, and
    // the only path from one to the other is the set the workspace holds.
    const granted = try f.pack(
        "core",
        "foundry:mod demo:core { name \"Core\" version 1 license \"MIT\" }",
        "@schema demo:torch { kind string }",
    );
    try f.manifest("foundry:mod demo:root { name \"Root\" version 1 license \"MIT\" requires [ { id demo:core } ] }\n");
    try f.write("pkg/lamp.fdt", "demo:torch demo:lamp { kind \"torch\" }\n");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{
        .dependencies = &.{.{ .path = granted }},
    }, &diags);
    defer workspace.deinit();
    try testing.expect(!diags.failed);

    var registry = data.Registry.init(gpa, .default);
    defer registry.deinit(gpa);
    try workspace.dependencies.registerSchemas(gpa, &registry, &diags);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    const identity = try compiler.compile(gpa, f.os, try f.at("pkg"), .{
        .dependencies = &workspace.dependencies,
    }, &registry, &diags, &bytes);
    defer gpa.free(identity.name);

    // Compiled, with the dependency's schema doing the checking: `demo:torch`'s `kind` is
    // a string and this record's value is one, so a set that had not been handed over
    // would have refused the record as an unknown schema instead.
    try testing.expect(!diags.failed);
    try testing.expectEqualStrings("demo:root", identity.name);
    try testing.expect(bytes.items.len > 0);
}

test "typed commands preserve every value kind through undo and redo" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.manifest("foundry:mod demo:root { name \"Root\" version 1 license \"MIT\" }\n");
    try f.write("pkg/records.fdt",
        \\@schema demo:item {
        \\    name       string
        \\    flag       bool                         (optional)
        \\    small      i32                          (optional)
        \\    signed     i64                          (optional)
        \\    count      u32                          (optional)
        \\    wide       u64                          (optional)
        \\    ratio      f32                          (optional)
        \\    precise    f64                          (optional)
        \\    target     id                           (optional)
        \\    detail     { amount u64  note string (optional) } (optional)
        \\    numbers    [u64]                        (optional)
        \\    rows       [{ n i64  label string (optional) }] (optional)
        \\    defaulted  u32                          (default 7)
        \\}
        \\demo:item demo:one { name "before" }
        \\
    );

    const gpa = testing.allocator;
    var open_diags = Diagnostics.init(gpa, .default);
    defer open_diags.deinit(gpa);
    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{
        .grants = .{ .edit = true },
    }, &open_diags);
    defer workspace.deinit();
    try testing.expect(!open_diags.failed);
    try testing.expectEqualStrings("records.fdt", workspace.documents[1].path);

    const record: edit.RecordRef = .{ .document = 1, .record = 0 };
    const edits = [_]struct { field: u32, value: edit.TypedValue }{
        .{ .field = 0, .value = .{ .value = .{ .string = "after" } } },
        .{ .field = 1, .value = .{ .value = .{ .bool = true } } },
        .{ .field = 2, .value = .{ .value = .{ .int = std.math.minInt(i32) } } },
        .{ .field = 3, .value = .{ .value = .{ .int = std.math.minInt(i64) } } },
        .{ .field = 4, .value = .{ .value = .{ .int = std.math.maxInt(u32) } } },
        .{ .field = 5, .value = .{ .value = .{ .int = std.math.maxInt(u64) } } },
        .{ .field = 6, .value = .{ .value = .{ .float = 1.5 } } },
        .{ .field = 7, .value = .{ .value = .{ .float = 1.2345678901234567 } } },
        .{ .field = 8, .value = .{
            .value = .{ .id = core.ContentId.fromString("demo:external") },
            .id_spellings = &.{"demo:external"},
        } },
        .{ .field = 9, .value = .{ .value = .{ .nested = &.{.{ .name = "amount", .value = .{ .int = std.math.maxInt(u64) } }} } } },
        .{ .field = 10, .value = .{ .value = .{ .list = &.{} } } },
        .{ .field = 11, .value = .{ .value = .{ .list = &.{} } } },
    };

    var op_diags = Diagnostics.init(gpa, .default);
    defer op_diags.deinit(gpa);
    var revision = workspace.revision();
    for (edits) |operation| {
        const result = try workspace.setValue(revision, record, &.{.{ .field = operation.field }}, operation.value, &op_diags);
        revision = result.revision;
    }
    revision = (try workspace.setValue(revision, record, &.{ .{ .field = 9 }, .{ .field = 1 } }, .{ .value = .{ .string = "nested" } }, &op_diags)).revision;
    revision = (try workspace.insertListItem(revision, record, &.{.{ .field = 10 }}, 0, .{ .value = .{ .int = 0 } }, &op_diags)).revision;
    revision = (try workspace.insertListItem(revision, record, &.{.{ .field = 10 }}, 1, .{ .value = .{ .int = std.math.maxInt(u64) } }, &op_diags)).revision;
    revision = (try workspace.insertListItem(revision, record, &.{.{ .field = 11 }}, 0, .{ .value = .{ .nested = &.{.{ .name = "n", .value = .{ .int = std.math.minInt(i64) } }} } }, &op_diags)).revision;
    revision = (try workspace.setValue(revision, record, &.{ .{ .field = 11 }, .{ .item = 0 }, .{ .field = 1 } }, .{ .value = .{ .string = "row" } }, &op_diags)).revision;
    revision = (try workspace.moveListItem(revision, record, &.{.{ .field = 10 }}, 1, 0, &op_diags)).revision;
    revision = (try workspace.removeListItem(revision, record, &.{.{ .field = 10 }}, 1, &op_diags)).revision;
    try testing.expect(!op_diags.failed);
    try testing.expect(workspace.dirty());

    var inspect_diags = Diagnostics.init(gpa, .default);
    defer inspect_diags.deinit(gpa);
    var inspection = try workspace.inspectRecord(record, &inspect_diags);
    const wide = try inspection.node(&.{.{ .field = 5 }});
    try testing.expect(wide.authored);
    try testing.expectEqual(@as(i128, std.math.maxInt(u64)), wide.value.?.int);
    const precise = try inspection.node(&.{.{ .field = 7 }});
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 1.2345678901234567))), @as(u64, @bitCast(precise.value.?.float)));
    const absent_default = try inspection.node(&.{.{ .field = 12 }});
    try testing.expect(!absent_default.authored);
    try testing.expect(absent_default.presence.? == .default);
    try testing.expectEqual(@as(i128, 7), absent_default.presence.?.default.int);
    const nested = try inspection.node(&.{ .{ .field = 9 }, .{ .field = 1 } });
    try testing.expectEqualStrings("nested", nested.value.?.string);
    const moved = try inspection.node(&.{ .{ .field = 10 }, .{ .item = 0 } });
    try testing.expectEqual(@as(i128, std.math.maxInt(u64)), moved.value.?.int);
    const row = try inspection.node(&.{ .{ .field = 11 }, .{ .item = 0 }, .{ .field = 1 } });
    try testing.expectEqualStrings("row", row.value.?.string);
    inspection.deinit();

    while (workspace.canUndo()) revision = (try workspace.undo(revision, &op_diags)).revision;
    try testing.expect(!workspace.dirty());
    try testing.expectEqualSlices(u8, workspace.documents[1].baseline, workspace.documents[1].bytes);
    while (workspace.canRedo()) revision = (try workspace.redo(revision, &op_diags)).revision;
    try testing.expect(workspace.dirty());
}

test "incomplete drafts commit, while stale and ill-typed commands are atomic" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.manifest("foundry:mod demo:root { name \"Root\" version 1 license \"MIT\" }\n");
    try f.write("pkg/records.fdt", "@schema demo:item { name string  count u64 (optional) }\ndemo:item demo:one { name \"one\" }\n");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);
    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{
        .grants = .{ .edit = true },
    }, &diags);
    defer workspace.deinit();
    const record: edit.RecordRef = .{ .document = 1, .record = 0 };

    const before = try gpa.dupe(u8, workspace.documents[1].bytes);
    defer gpa.free(before);
    const original_revision = workspace.revision();
    try testing.expectError(error.WrongType, workspace.setValue(original_revision, record, &.{.{ .field = 1 }}, .{ .value = .{ .string = "wrong" } }, &diags));
    try testing.expectEqual(original_revision, workspace.revision());
    try testing.expectEqualSlices(u8, before, workspace.documents[1].bytes);
    try testing.expect(!workspace.canUndo());

    var result = try workspace.setValue(original_revision, record, &.{.{ .field = 1 }}, .{ .value = .{ .int = std.math.maxInt(u64) } }, &diags);
    const after_valid = try gpa.dupe(u8, workspace.documents[1].bytes);
    defer gpa.free(after_valid);
    try testing.expectError(error.StaleRevision, workspace.unsetField(original_revision, record, &.{.{ .field = 0 }}, &diags));
    try testing.expectEqualSlices(u8, after_valid, workspace.documents[1].bytes);

    var incomplete_diags = Diagnostics.init(gpa, .default);
    defer incomplete_diags.deinit(gpa);
    result = try workspace.unsetField(result.revision, record, &.{.{ .field = 0 }}, &incomplete_diags);
    try testing.expect(incomplete_diags.failed);
    try testing.expect(std.mem.indexOf(u8, incomplete_diags.items.items[0].message, "incomplete draft") != null);
    var inspect_diags = Diagnostics.init(gpa, .default);
    defer inspect_diags.deinit(gpa);
    var view = try workspace.inspectRecord(record, &inspect_diags);
    const name = try view.node(&.{.{ .field = 0 }});
    try testing.expect(!name.authored);
    try testing.expect(name.presence.? == .required);
    view.deinit();

    _ = try workspace.undo(result.revision, &diags);
    try testing.expectEqualSlices(u8, after_valid, workspace.documents[1].bytes);

    var create_diags = Diagnostics.init(gpa, .default);
    defer create_diags.deinit(gpa);
    const created = try workspace.createRecord(workspace.revision(), 1, "demo:item", "demo:draft", &create_diags);
    try testing.expect(create_diags.failed);
    try testing.expect(std.mem.indexOf(u8, create_diags.items.items[0].message, "incomplete draft") != null);
    var draft = try workspace.inspectRecord(.{ .document = 1, .record = 1 }, &inspect_diags);
    try testing.expect(!(try draft.node(&.{.{ .field = 0 }})).authored);
    draft.deinit();
    _ = try workspace.undo(created.revision, &diags);
    try testing.expect(std.mem.indexOf(u8, workspace.documents[1].bytes, "demo:draft") == null);
}

test "create duplicate delete and bounded history preserve exact source" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.manifest("foundry:mod demo:root { name \"Root\" version 1 license \"MIT\" }\n");
    try f.write("pkg/records.fdt",
        \\@schema demo:item { name string }
        \\demo:item demo:one {
        \\    # copied with the record
        \\    name "one"
        \\}
        \\
    );

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);
    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{
        .grants = .{ .edit = true },
        .limits = .{ .max_history_commands = 2 },
    }, &diags);
    defer workspace.deinit();
    const one: edit.RecordRef = .{ .document = 1, .record = 0 };
    var revision = workspace.revision();
    revision = (try workspace.duplicateRecord(revision, one, 1, "demo:two", &diags)).revision;
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, workspace.documents[1].bytes, "# copied with the record"));

    // The duplicate is the second local record in the same parse.
    const two: edit.RecordRef = .{ .document = 1, .record = 1 };
    revision = (try workspace.setValue(revision, two, &.{.{ .field = 0 }}, .{ .value = .{ .string = "two" } }, &diags)).revision;
    revision = (try workspace.deleteRecord(revision, one, &diags)).revision;
    try testing.expect(workspace.historyTruncated());
    try testing.expect(std.mem.indexOf(u8, workspace.documents[1].bytes, "demo:one") == null);
    try testing.expect(std.mem.indexOf(u8, workspace.documents[1].bytes, "demo:two") != null);

    revision = (try workspace.undo(revision, &diags)).revision;
    revision = (try workspace.undo(revision, &diags)).revision;
    try testing.expectError(error.HistoryEmpty, workspace.undo(revision, &diags));
    // The oldest command was evicted, so the original duplicate remains.
    try testing.expect(std.mem.indexOf(u8, workspace.documents[1].bytes, "demo:two") != null);

    // A new command after Undo clears Redo.
    _ = try workspace.setValue(revision, two, &.{.{ .field = 0 }}, .{ .value = .{ .string = "new branch" } }, &diags);
    try testing.expect(!workspace.canRedo());
}

test "a dependency override uses exact readers and refuses an unspellable id" {
    const f = try Fixture.init();
    defer f.deinit();
    const granted = try f.pack("dep", "foundry:mod dep:root { name \"Dependency\" version 1 license \"MIT\" }",
        \\@schema dep:exact {
        \\    wide u64
        \\    precise f64
        \\    target id
        \\    values [u64]
        \\    detail { signed i64 }
        \\    absent string (optional)
        \\}
        \\dep:exact dep:source {
        \\    wide 18446744073709551615
        \\    precise 1.2345678901234567
        \\    target dep:target
        \\    values [0 18446744073709551615]
        \\    detail { signed -9223372036854775808 }
        \\}
        \\dep:exact dep:target {
        \\    wide 0 precise 0.0 target dep:target values [] detail { signed 0 }
        \\}
        \\dep:exact dep:unknown {
        \\    wide 1 precise 1.0 target dep:missing values [] detail { signed 1 }
        \\}
    );
    try f.manifest("foundry:mod demo:root { name \"Root\" version 1 license \"MIT\" requires [ { id dep:root } ] }\n");
    try f.write("pkg/records.fdt", "");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);
    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{
        .dependencies = &.{.{ .path = granted }},
        .grants = .{ .edit = true },
    }, &diags);
    defer workspace.deinit();
    try testing.expect(!diags.failed);

    const result = try workspace.createOverride(workspace.revision(), 1, .{ .package = 0, .record = 1 }, &diags);
    try testing.expect(std.mem.indexOf(u8, workspace.documents[1].bytes, "wide 18446744073709551615") != null);
    try testing.expect(std.mem.indexOf(u8, workspace.documents[1].bytes, "precise 1.2345678901234567") != null);
    try testing.expect(std.mem.indexOf(u8, workspace.documents[1].bytes, "target dep:target") != null);

    var inspect_diags = Diagnostics.init(gpa, .default);
    defer inspect_diags.deinit(gpa);
    var view = try workspace.inspectRecord(.{ .document = 1, .record = 0 }, &inspect_diags);
    try testing.expectEqual(@as(i128, std.math.maxInt(u64)), (try view.node(&.{.{ .field = 0 }})).value.?.int);
    try testing.expect(!(try view.node(&.{.{ .field = 5 }})).authored);
    view.deinit();
    _ = try workspace.undo(result.revision, &diags);
    try testing.expectEqual(@as(usize, 0), workspace.documents[1].bytes.len);
    const revision = workspace.revision();
    try testing.expectError(error.UnspelledId, workspace.createOverride(revision, 1, .{ .package = 0, .record = 3 }, &diags));
    try testing.expectEqual(revision, workspace.revision());
    try testing.expectEqual(@as(usize, 0), workspace.documents[1].bytes.len);
}

test "a command larger than the history budget changes neither bytes nor revision" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.manifest("foundry:mod demo:root { name \"Root\" version 1 license \"MIT\" }\n");
    try f.write("pkg/records.fdt", "@schema demo:item { name string }\ndemo:item demo:one { name \"one\" }\n");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);
    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{
        .grants = .{ .edit = true },
        .limits = .{ .max_history_bytes = 1 },
    }, &diags);
    defer workspace.deinit();
    const before = try gpa.dupe(u8, workspace.documents[1].bytes);
    defer gpa.free(before);
    const revision = workspace.revision();
    try testing.expectError(error.HistoryLimit, workspace.setValue(revision, .{ .document = 1, .record = 0 }, &.{.{ .field = 0 }}, .{ .value = .{ .string = "a change larger than one byte" } }, &diags));
    try testing.expectEqual(revision, workspace.revision());
    try testing.expectEqualSlices(u8, before, workspace.documents[1].bytes);
    try testing.expect(!workspace.canUndo());
}

test "allocation failure during a command preserves bytes revision and history" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.manifest("foundry:mod demo:root { name \"Root\" version 1 license \"MIT\" }\n");
    try f.write("pkg/records.fdt", "@schema demo:item { name string }\ndemo:item demo:one { name \"one\" }\n");
    const root = try f.at("pkg");

    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator, os: *Os, package_root: []const u8) !void {
            var diags = Diagnostics.init(gpa, .default);
            defer diags.deinit(gpa);
            var workspace = try Workspace.open(gpa, os, package_root, .{
                .grants = .{ .edit = true },
            }, &diags);
            defer workspace.deinit();

            const document = &workspace.documents[1];
            const before = try gpa.dupe(u8, document.bytes);
            defer gpa.free(before);
            const revision = workspace.revision();
            const result = workspace.setValue(revision, .{ .document = 1, .record = 0 }, &.{.{ .field = 0 }}, .{ .value = .{ .string = "after" } }, &diags) catch |err| {
                if (err == error.OutOfMemory) {
                    try testing.expectEqual(revision, workspace.revision());
                    try testing.expectEqualSlices(u8, before, document.bytes);
                    try testing.expect(!workspace.canUndo());
                }
                return err;
            };
            try testing.expectEqual(revision + 1, result.revision);
            try testing.expect(workspace.canUndo());
            try testing.expect(std.mem.indexOf(u8, document.bytes, "\"after\"") != null);
        }
    }.run, .{ f.os, root });
}

test "save all commits its stable prefix and preserves an external conflict" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.manifest(
        "foundry:mod demo:root { name \"Root\" version 1 license \"MIT\" }\n" ++
            "@schema demo:item { name string }\n",
    );
    try f.write("pkg/a.fdt", "demo:item demo:a { name \"a\" }\n");
    try f.write("pkg/b.fdt", "demo:item demo:b { name \"b\" }\n");

    const gpa = testing.allocator;
    var open_diags = Diagnostics.init(gpa, .default);
    defer open_diags.deinit(gpa);
    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{
        .grants = .{ .edit = true, .save = true },
    }, &open_diags);
    defer workspace.deinit();
    try testing.expect(!open_diags.failed);

    const a = documentNamed(&workspace, "a.fdt");
    const b = documentNamed(&workspace, "b.fdt");
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);
    var revision = workspace.revision();
    revision = (try workspace.setValue(revision, .{ .document = a, .record = 0 }, &.{.{ .field = 0 }}, .{ .value = .{ .string = "saved-a" } }, &diags)).revision;
    revision = (try workspace.setValue(revision, .{ .document = b, .record = 0 }, &.{.{ .field = 0 }}, .{ .value = .{ .string = "draft-b" } }, &diags)).revision;
    try f.write("pkg/b.fdt", "demo:item demo:b { name \"outside-b\" }\n");

    var save_diags = Diagnostics.init(gpa, .default);
    defer save_diags.deinit(gpa);
    var result = try workspace.saveAll(revision, &save_diags);
    defer result.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), result.items().len);
    try testing.expectEqual(a, result.items()[0].document);
    try testing.expect(result.items()[0].outcome == .saved);
    try testing.expectEqual(b, result.items()[1].document);
    try testing.expect(result.items()[1].outcome == .failed);
    try testing.expectEqual(save.Failure.external_change, result.items()[1].outcome.failed);
    try testing.expect(!workspace.documents[a].dirty());
    try testing.expect(workspace.documents[b].dirty());
    try testing.expect(workspace.documents[b].externally_changed);
    const disk_a = try f.os.readFileConfined(gpa, try f.at("pkg"), "a.fdt", 1024);
    defer gpa.free(disk_a.bytes);
    try testing.expect(std.mem.indexOf(u8, disk_a.bytes, "saved-a") != null);

    // Refresh cannot silently destroy the draft. Discard and refresh are two explicit,
    // separately revisioned operations, after which the external bytes are the baseline.
    var refresh_diags = Diagnostics.init(gpa, .default);
    defer refresh_diags.deinit(gpa);
    try testing.expectError(error.DirtyDocument, workspace.refreshDocument(result.revision, b, &refresh_diags));
    revision = try workspace.discardDocument(result.revision, b, &refresh_diags);
    revision = try workspace.refreshDocument(revision, b, &refresh_diags);
    try testing.expectEqualStrings("demo:item demo:b { name \"outside-b\" }\n", workspace.documents[b].bytes);
    try testing.expect(!workspace.documents[b].dirty());

    // A crash-left token refuses another cooperating writer and is never guessed stale.
    revision = (try workspace.setValue(revision, .{ .document = a, .record = 0 }, &.{.{ .field = 0 }}, .{ .value = .{ .string = "later" } }, &diags)).revision;
    try f.write("pkg/.foundry-author.lock", "some other session\n");
    try testing.expectError(error.Busy, workspace.saveDocument(revision, a, &save_diags));
    try f.os.deleteFileConfined(try f.at("pkg"), save.lock_file);

    // New names are create-if-absent. An unrelated writer which wins is preserved.
    try testing.expectError(error.InvalidDocumentName, workspace.createDocument(revision, ".hidden.fdt"));
    const fresh = try workspace.createDocument(revision, "new.fdt");
    revision = workspace.revision();
    const created = try workspace.saveDocument(revision, fresh, &save_diags);
    try testing.expect(created.published);
    revision = created.revision;
    const taken = try workspace.createDocument(revision, "taken.fdt");
    revision = workspace.revision();
    try f.write("pkg/taken.fdt", "winner\n");
    try testing.expectError(error.ExternalChange, workspace.saveDocument(revision, taken, &save_diags));
    const winner = try f.os.readFileConfined(gpa, try f.at("pkg"), "taken.fdt", 1024);
    defer gpa.free(winner.bytes);
    try testing.expectEqualStrings("winner\n", winner.bytes);
}

test "candidate builds match the compiler and a failed generation keeps the last good build" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.manifest(
        "foundry:mod demo:root { name \"Root\" version 1 license \"MIT\" }\n" ++
            "@schema demo:item { name string }\n",
    );
    try f.write("pkg/records.fdt", "demo:item demo:one { name \"one\" }\n");
    try f.write("pkg/grids/town.grid", "1 1 1\n1 0 1\n1 1 1\n");
    const output = try f.at("output");
    try f.os.createDirPath(output);

    const gpa = testing.allocator;
    var open_diags = Diagnostics.init(gpa, .default);
    defer open_diags.deinit(gpa);
    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{
        .output_root = output,
        .grants = .{ .build = true },
    }, &open_diags);
    defer workspace.deinit();
    try testing.expect(!open_diags.failed);

    var build_diags = Diagnostics.init(gpa, .default);
    defer build_diags.deinit(gpa);
    const first = try workspace.build(workspace.revision(), &build_diags);
    const first_info = try workspace.buildInfo(first);
    try testing.expectEqual(@as(u32, 1), workspace.buildCount());

    // The ordinary compiler over the same bytes and options is the byte oracle; authoring
    // has no second compiler or editor-only package format.
    const direct_generated = try f.at("direct-generated");
    var registry = data.Registry.init(gpa, .default);
    defer registry.deinit(gpa);
    var direct_diags = Diagnostics.init(gpa, .default);
    defer direct_diags.deinit(gpa);
    var direct: std.ArrayList(u8) = .empty;
    defer direct.deinit(gpa);
    const identity = try compiler.compile(gpa, f.os, try f.at("pkg"), .{
        .assets_out = direct_generated,
    }, &registry, &direct_diags, &direct);
    defer gpa.free(identity.name);
    try testing.expectEqualSlices(u8, direct.items, first_info.package_bytes);

    const first_grid_rel = try std.fmt.allocPrint(gpa, "{s}/runtime/assets/grids/town.fgrid", .{first_info.relative_dir});
    defer gpa.free(first_grid_rel);
    const first_grid = try f.os.readFileConfined(gpa, output, first_grid_rel, 1024 * 1024);
    defer gpa.free(first_grid.bytes);
    const direct_grid = try f.os.readFileConfined(gpa, direct_generated, "grids/town.fgrid", 1024 * 1024);
    defer gpa.free(direct_grid.bytes);
    try testing.expectEqualSlices(u8, direct_grid.bytes, first_grid.bytes);

    // Failure happens after a fresh candidate and generated-output directory exist. Only
    // that incomplete tree is cleaned; the prior handle and its bytes remain live.
    try f.write("pkg/grids/town.grid", "1 1 1\n1 0\n");
    var failure_diags = Diagnostics.init(gpa, .default);
    defer failure_diags.deinit(gpa);
    try testing.expectError(error.ContentInvalid, workspace.build(workspace.revision(), &failure_diags));
    try testing.expectEqual(@as(u32, 1), workspace.buildCount());
    const retained = try workspace.buildInfo(first);
    try testing.expectEqualSlices(u8, direct.items, retained.package_bytes);
    _ = try f.os.statFileConfined(output, first_grid_rel);

    try f.write("pkg/grids/town.grid", "1 1 1\n1 0 1\n1 1 1\n");
    var second_diags = Diagnostics.init(gpa, .default);
    defer second_diags.deinit(gpa);
    const second = try workspace.build(workspace.revision(), &second_diags);
    const second_info = try workspace.buildInfo(second);
    try testing.expect(!std.mem.eql(u8, first_info.relative_dir, second_info.relative_dir));
    try testing.expectEqual(@as(u32, 2), workspace.buildCount());

    var release_diags = Diagnostics.init(gpa, .default);
    defer release_diags.deinit(gpa);
    try workspace.releaseBuild(first, &release_diags);
    try testing.expectError(error.InvalidHandle, workspace.buildInfo(first));
    _ = try workspace.buildInfo(second);
    try testing.expectEqual(@as(u32, 1), workspace.buildCount());
}

test "validation accepts drafts but reports an incomplete candidate without publishing it" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.manifest(
        "foundry:mod demo:root { name \"Root\" version 1 license \"MIT\" }\n" ++
            "@schema demo:item { name string }\n",
    );
    try f.write("pkg/records.fdt", "demo:item demo:one { name \"one\" }\n");
    const output = try f.at("output");
    try f.os.createDirPath(output);

    const gpa = testing.allocator;
    var open_diags = Diagnostics.init(gpa, .default);
    defer open_diags.deinit(gpa);
    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{
        .output_root = output,
        .grants = .{ .edit = true, .build = true },
    }, &open_diags);
    defer workspace.deinit();
    const records = documentNamed(&workspace, "records.fdt");

    var edit_diags = Diagnostics.init(gpa, .default);
    defer edit_diags.deinit(gpa);
    const edit_result = try workspace.unsetField(workspace.revision(), .{ .document = records, .record = 0 }, &.{.{ .field = 0 }}, &edit_diags);
    try testing.expect(edit_diags.failed);
    var validation_diags = Diagnostics.init(gpa, .default);
    defer validation_diags.deinit(gpa);
    try testing.expectError(error.ContentInvalid, workspace.validate(edit_result.revision, &validation_diags));
    try testing.expect(validation_diags.failed);
    try testing.expectEqualStrings("records.fdt", validation_diags.items.items[0].location.file);
    try testing.expectEqual(@as(u32, 0), workspace.buildCount());
    try testing.expectEqual(@as(usize, 0), try countFixtureEntries(f.os, output));
}

test "build roots cannot alias sources and a swapped source directory is never followed" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.manifest("foundry:mod demo:root { name \"Root\" version 1 license \"MIT\" }\n");
    try f.write("pkg/nested/records.fdt", "@schema demo:item { }\ndemo:item demo:inside { }\n");

    const gpa = testing.allocator;
    var alias_diags = Diagnostics.init(gpa, .default);
    defer alias_diags.deinit(gpa);
    const source_root = try f.at("pkg");
    try testing.expectError(error.InvalidGrant, Workspace.open(gpa, f.os, source_root, .{
        .output_root = source_root,
        .grants = .{ .build = true },
    }, &alias_diags));

    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try f.write("outside/records.fdt", "@schema demo:item { }\ndemo:item demo:outside { }\n");
    const output = try f.at("output");
    try f.os.createDirPath(output);
    var open_diags = Diagnostics.init(gpa, .default);
    defer open_diags.deinit(gpa);
    var workspace = try Workspace.open(gpa, f.os, source_root, .{
        .output_root = output,
        .grants = .{ .build = true },
    }, &open_diags);
    defer workspace.deinit();

    try std.Io.Dir.rename(f.tmp.dir, "pkg/nested", f.tmp.dir, "pkg/held", testing.io);
    try f.tmp.dir.symLink(testing.io, try f.at("outside"), "pkg/nested", .{ .is_directory = true });
    var build_diags = Diagnostics.init(gpa, .default);
    defer build_diags.deinit(gpa);
    try testing.expectError(error.ExternalChange, workspace.build(workspace.revision(), &build_diags));
    try testing.expectEqual(@as(u32, 0), workspace.buildCount());
    try testing.expectEqual(@as(usize, 0), try countFixtureEntries(f.os, output));
}

fn countFixtureEntries(os: *Os, path: []const u8) !usize {
    var listing = try os.listDir(testing.allocator, path);
    defer listing.deinit();
    return listing.entries.len;
}
