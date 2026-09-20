//! The v4 authoring boundary: `author.Service`, published (ADR-0042, `editor.md` §9).
//!
//! **The editor gets no private path** (I4). Everything the standalone editor will do to a
//! package it does through these forty-seven calls, which is the whole argument for building
//! them before the editor rather than after: a capability the editor needed and this table
//! lacked would otherwise be discovered as a shortcut.
//!
//! **This file translates and nothing else.** It resolves a handle, validates what came from
//! the other side, calls one `author` function and maps the answer. It owns no workspace, no
//! parse and no build — the host owns the service, the service owns the workspaces, and the
//! rings in `host.zig` own only the identities this boundary had to invent because `author`
//! has no handle for a document, a node or a build of its own.
//!
//! **Three lifetimes, stated rather than implied.** A workspace handle lives until it is
//! closed. A document or build handle lives as long as its workspace. A **node** handle dies
//! at the next accepted command, even one that did not touch it, because a node is a position
//! in a parse and the command replaced the parse (`editor.md` §5). Borrowed text dies sooner
//! still: with the next scalar read for a formatted number, and after `max_author_readers`
//! more records for a name or a string. A client that wants to keep any of it copies it.
//!
//! **Numbers cross as text.** See `author_types.zig`: an authoring read or write of a `u64`
//! or an `f64` carries its canonical spelling plus the declared field type, so nothing an
//! author typed is narrowed on the way through. v1–v3's `record_get_f32` is untouched and
//! still means what it always did.
//!
//! Design: `docs/design/editor.md` §9; the header is `foundry.h`.

const std = @import("std");
const author = @import("author");
const core = @import("core");
const data = @import("data");

const author_types = @import("author_types.zig");
const host_mod = @import("host.zig");
const types = @import("types.zig");

const Bool = types.Bool;
const ContentId = types.ContentId;
const Cursor = types.Cursor;
const Result = types.Result;
const Str = types.Str;

const Selector = author.Selector;
const Value = data.Value;

/// An empty spelling table, for emitting a number — which needs none. Taking its address is
/// what `data.emit.Context` wants, and a file-level constant is the one place it can come
/// from without allocating on a read.
const no_spellings: data.emit.Spellings = .empty;

/// The salts that keep one walk's cursor from being accepted by another. Arbitrary, distinct
/// and never reused, exactly as the v3 mod walks do it.
const salt_workspace: u32 = 0x4157_0001;
const salt_document: u32 = 0x4157_0002;
const salt_schema: u32 = 0x4157_0003;
const salt_record: u32 = 0x4157_0004;
const salt_dependency: u32 = 0x4157_0005;
const salt_dependency_record: u32 = 0x4157_0006;
const salt_preview: u32 = 0x4157_0007;
const salt_diagnostic: u32 = 0x4157_0008;
const salt_save_entry: u32 = 0x4157_0009;
const salt_export: u32 = 0x4157_000a;

pub fn Of(comptime H: type) type {
    return struct {
        const Active = struct {
            host: *H,
            service: *author.Service,

            fn entry(self: Active, handle: types.Workspace) ?*author.service.Entry {
                return self.service.entry(handle.unwrap(author.ServiceHandle));
            }

            fn workspace(self: Active, handle: types.Workspace) ?*author.Workspace {
                return &(self.entry(handle) orelse return null).workspace;
            }

            /// A document handle carries its workspace, so this resolves both at once and
            /// answers null if either half is stale.
            fn document(self: Active, handle: types.Document) ?Located {
                const located = H.authorDocumentOf(handle) orelse return null;
                const item = self.service.entry(located.workspace) orelse return null;
                if (located.index >= item.workspace.documents.len) return null;
                return .{ .handle = .{ .bits = located.workspace.bits() }, .entry = item, .index = located.index };
            }
        };

        const Located = struct {
            handle: types.Workspace,
            entry: *author.service.Entry,
            index: u32,
        };

        fn active() ?Active {
            const host = H.current() orelse return null;
            return .{ .host = host, .service = host.author_service orelse return null };
        }

        /// One generation per walk and per state of the service: its counter, the length
        /// being walked and a salt naming the walk.
        fn generation(a: Active, count: usize, salt: u32) u32 {
            var value = a.service.generation ^ (@as(u32, @truncate(count)) *% 0x9e37_79b9) ^ salt;
            if (value == 0) value = std.math.maxInt(u32);
            return value;
        }

        fn walk(c: *const Cursor, expected: u32, count: usize) ?usize {
            if (!c.isBegin() and c.generation() != expected) return null;
            return @min(c.index(), count);
        }

        fn advance(c: *Cursor, expected: u32, next: usize) void {
            c.* = .at(expected, @intCast(next));
        }

        // -- Error mapping ---------------------------------------------------------
        //
        // Every one of these is written out rather than defaulted. §9 asks for it in so
        // many words: an ordinary content or file error must have a mapping and a
        // diagnostic, not fall through to an internal-bug log that tells a mod author
        // their editor is broken when their file simply has a typo in it.

        fn editResult(err: author.EditError) Result {
            return switch (err) {
                error.OutOfMemory => .out_of_memory,
                error.StaleRevision => .refused,
                error.RevisionExhausted => .limit,
                error.InvalidDocument, error.InvalidRecord => .invalid_argument,
                error.InvalidDependencyRecord, error.InvalidPath => .invalid_argument,
                error.InvalidDocumentName => .invalid_argument,
                error.DuplicateDocument, error.DuplicateRecord => .already_exists,
                error.ReadOnlyDocument, error.WriteNotGranted => .refused,
                error.NotPresent => .not_found,
                error.NotAList => .invalid_argument,
                error.SourceInvalid, error.DependencyInvalid => .invalid_argument,
                error.SchemaUnavailable => .refused,
                error.HistoryEmpty => .not_found,
                error.HistoryLimit, error.DocumentBudget => .limit,
                error.NoChange => .ok,
                // `data.splice` and `data.emit`, which an edit reaches through. Every one
                // of them is something about the caller's value or the file's bytes.
                error.StaleSource, error.InvalidSpan, error.InvalidEdit => .refused,
                error.IndexOutOfRange => .invalid_argument,
                error.SourceTooLarge, error.NestingTooDeep => .limit,
                error.ListTooLong, error.TooManyFields => .limit,
                error.WrongType, error.IntegerOutOfRange, error.FloatNotExact => .invalid_argument,
                error.NotFinite, error.InvalidUtf8, error.InvalidId => .invalid_argument,
                error.UnspelledId, error.IdCollision => .invalid_argument,
                error.InvalidFieldName, error.UnknownField => .invalid_argument,
                error.DuplicateField, error.FieldCountMismatch => .invalid_argument,
                error.InvalidIndent => .invalid_argument,
            };
        }

        fn refreshResult(err: author.workspace.RefreshError) Result {
            return switch (err) {
                error.OutOfMemory => .out_of_memory,
                error.StaleRevision => .refused,
                error.RevisionExhausted => .limit,
                error.InvalidDocument => .invalid_argument,
                error.WriteNotGranted, error.DirtyDocument => .refused,
                error.NoChange => .ok,
                error.DocumentBudget => .limit,
                error.IoFailed => .internal,
            };
        }

        fn saveResultCode(err: author.save_mod.Error) Result {
            return switch (err) {
                error.OutOfMemory => .out_of_memory,
                error.StaleRevision => .refused,
                error.RevisionExhausted => .limit,
                error.InvalidDocument => .invalid_argument,
                error.WriteNotGranted, error.Busy, error.ExternalChange => .refused,
                error.DocumentBudget => .limit,
                error.IoFailed => .internal,
            };
        }

        fn buildResultCode(err: author.build_mod.Error) Result {
            return switch (err) {
                error.OutOfMemory => .out_of_memory,
                error.StaleRevision => .refused,
                error.InvalidState, error.DirtyDocuments => .refused,
                error.ExternalChange, error.Busy => .refused,
                error.BuildNotGranted, error.OutputUnavailable => .refused,
                error.BuildLimit, error.SnapshotLimit => .limit,
                error.ContentInvalid => .invalid_argument,
                error.IoFailed => .internal,
                error.InvalidHandle => .invalid_handle,
            };
        }

        fn serviceResultCode(err: author.service.Error) Result {
            return switch (err) {
                error.OutOfMemory => .out_of_memory,
                error.InvalidHandle => .invalid_handle,
                error.Limit => .limit,
                error.PreviewUnavailable => .unavailable,
                error.PreviewRefused, error.PreviewHoldsBuild => .refused,
                error.ExportUnavailable => .unsupported,
                error.IoFailed => .internal,
                error.ContentInvalid => .invalid_argument,
            };
        }

        // -- Workspace -------------------------------------------------------------

        pub fn workspaceNext(cursor: ?*Cursor, out: ?*types.Workspace) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;

            const count = a.service.count();
            const expected = generation(a, count, salt_workspace);
            const at = walk(c, expected, count) orelse return .refused;
            if (at >= count) return .end;

            const handle = a.service.at(@intCast(at)) orelse return .end;
            slot.* = .{ .bits = handle.bits() };
            advance(c, expected, at + 1);
            return .ok;
        }

        pub fn workspaceInfo(workspace: types.Workspace, out: ?*author_types.WorkspaceInfo) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const item = a.entry(workspace) orelse return .invalid_handle;
            const ws = &item.workspace;

            var externally_changed = false;
            for (ws.documents) |document| {
                if (document.externally_changed) externally_changed = true;
            }

            slot.* = .{
                .revision = ws.revision(),
                .package_name = if (ws.packageName()) |name| .from(name) else .empty,
                .package_version = ws.packageVersion(),
                .document_count = @intCast(ws.documents.len),
                .dependency_count = ws.dependencies.count(),
                .build_count = ws.buildCount(),
                .diagnostic_count = @intCast(item.diags.count()),
                .suppressed_diagnostics = item.diags.suppressed,
                .export_count = @intCast(item.exports.len),
                .can_edit = types.boolOut(ws.grants.edit),
                .can_save = types.boolOut(ws.grants.save),
                .can_build = types.boolOut(ws.grants.build),
                .can_preview = types.boolOut(item.preview_grant != null),
                .dirty = types.boolOut(ws.dirty()),
                .externally_changed = types.boolOut(externally_changed),
                .can_undo = types.boolOut(ws.canUndo()),
                .can_redo = types.boolOut(ws.canRedo()),
                .history_truncated = types.boolOut(ws.historyTruncated()),
                .has_manifest = types.boolOut(ws.packageName() != null),
            };
            return .ok;
        }

        pub fn workspaceRevision(workspace: types.Workspace, out: ?*u64) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const ws = a.workspace(workspace) orelse return .invalid_handle;
            slot.* = ws.revision();
            return .ok;
        }

        pub fn workspaceLimits(workspace: types.Workspace, out: ?*author_types.Limits) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const ws = a.workspace(workspace) orelse return .invalid_handle;
            const limits = ws.limits;
            slot.* = .{
                .max_source_bytes = limits.max_source_bytes,
                .max_total_source_bytes = limits.max_total_source_bytes,
                .max_document_bytes = limits.max_document_bytes,
                .max_history_bytes = limits.max_history_bytes,
                .max_snapshot_bytes = limits.max_snapshot_bytes,
                .max_history_commands = limits.max_history_commands,
                .max_live_builds = limits.max_live_builds,
                .max_sources = limits.walk.max_sources,
                .max_diagnostics = limits.content.max_diagnostics,
                .max_nesting_depth = limits.content.max_nesting_depth,
                .max_list_elements = @intCast(limits.content.max_list_elements),
            };
            return .ok;
        }

        // -- Documents -------------------------------------------------------------

        pub fn documentNext(workspace: types.Workspace, cursor: ?*Cursor, out: ?*types.Document) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const item = a.entry(workspace) orelse return .invalid_handle;

            const count = item.workspace.documents.len;
            const expected = generation(a, count, salt_document);
            const at = walk(c, expected, count) orelse return .refused;
            if (at >= count) return .end;

            slot.* = H.authorDocumentHandle(workspace.unwrap(author.ServiceHandle), @intCast(at)) orelse return .limit;
            advance(c, expected, at + 1);
            return .ok;
        }

        pub fn documentInfo(document: types.Document, out: ?*author_types.DocumentInfo) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const located = a.document(document) orelse return .invalid_handle;
            const doc = located.entry.workspace.documents[located.index];
            slot.* = .{
                .path = .from(doc.path),
                .source_bytes = doc.bytes.len,
                .index = located.index,
                .dirty = types.boolOut(doc.dirty()),
                .on_disk = types.boolOut(doc.on_disk),
                .externally_changed = types.boolOut(doc.externally_changed),
                .parseable = types.boolOut(doc.parseable),
                .editable = types.boolOut(doc.editable),
            };
            return .ok;
        }

        pub fn documentCreate(
            workspace: types.Workspace,
            expected_revision: u64,
            path: Str,
            out: ?*types.Document,
        ) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const text = path.utf8() orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const item = a.entry(workspace) orelse return .invalid_handle;

            item.begin(a.service.gpa);
            const index = item.workspace.createDocument(expected_revision, text) catch |err| return editResult(err);
            item.end(item.workspace.revision());
            a.service.moved();
            a.host.changedAuthoring();

            slot.* = H.authorDocumentHandle(workspace.unwrap(author.ServiceHandle), index) orelse return .limit;
            return .ok;
        }

        pub fn documentRefresh(document: types.Document, expected_revision: u64, out: ?*u64) callconv(.c) Result {
            return refreshOrDiscard(document, expected_revision, out, .refresh);
        }

        pub fn documentDiscard(document: types.Document, expected_revision: u64, out: ?*u64) callconv(.c) Result {
            return refreshOrDiscard(document, expected_revision, out, .discard);
        }

        fn refreshOrDiscard(
            document: types.Document,
            expected_revision: u64,
            out: ?*u64,
            which: enum { refresh, discard },
        ) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const located = a.document(document) orelse return .invalid_handle;
            const item = located.entry;

            item.begin(a.service.gpa);
            const revision = switch (which) {
                .refresh => item.workspace.refreshDocument(expected_revision, located.index, &item.diags),
                .discard => item.workspace.discardDocument(expected_revision, located.index, &item.diags),
            } catch |err| switch (err) {
                // Nothing to do is not a failure: a refresh of a document that already
                // matches its file has done exactly what was asked of it.
                error.NoChange => {
                    item.end(item.workspace.revision());
                    slot.* = item.workspace.revision();
                    return .ok;
                },
                else => return refreshResult(err),
            };
            item.end(revision);
            a.service.moved();
            a.host.changedAuthoring();
            slot.* = revision;
            return .ok;
        }

        pub fn documentCopySource(
            document: types.Document,
            buffer: ?[*]u8,
            capacity: u64,
            needed: ?*u64,
        ) callconv(.c) Result {
            const a = active() orelse return .unavailable;
            const located = a.document(document) orelse return .invalid_handle;
            return copyOut(located.entry.workspace.documents[located.index].bytes, buffer, capacity, needed);
        }

        // -- Schema tree -----------------------------------------------------------

        pub fn schemaNext(workspace: types.Workspace, cursor: ?*Cursor, out: ?*types.SchemaNode) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const item = a.entry(workspace) orelse return .invalid_handle;

            const names = item.workspace.schemaNames();
            const expected = generation(a, names.len, salt_schema);
            const at = walk(c, expected, names.len) orelse return .refused;
            if (at >= names.len) return .end;

            slot.* = a.host.issueAuthorSchemaNode(.{
                .workspace = workspace.unwrap(author.ServiceHandle),
                .schema = data.SchemaId.fromStringUnchecked(names[at]),
            });
            advance(c, expected, at + 1);
            return .ok;
        }

        pub fn schemaFind(workspace: types.Workspace, name: Str, out: ?*types.SchemaNode) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const text = name.utf8() orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const item = a.entry(workspace) orelse return .invalid_handle;

            for (item.workspace.schemaNames()) |known| {
                if (!std.mem.eql(u8, known, text)) continue;
                slot.* = a.host.issueAuthorSchemaNode(.{
                    .workspace = workspace.unwrap(author.ServiceHandle),
                    .schema = data.SchemaId.fromStringUnchecked(known),
                });
                return .ok;
            }
            return .not_found;
        }

        /// A schema node's declaration, resolved fresh each time: the registry outlives
        /// every node handle, so there is nothing to cache and nothing to go stale.
        const SchemaSite = struct {
            /// The schema this node is inside.
            schema: *const data.Schema,
            name: []const u8,
            /// Null at the root, which is the schema itself.
            field: ?data.Field,
            field_type: data.FieldType,
            is_element: bool,
            child_count: u32,
            index: u32,
        };

        fn schemaSiteOf(a: Active, node: H.AuthorSchemaNode) ?SchemaSite {
            const item = a.service.entry(node.workspace) orelse return null;
            const spelling = item.workspace.schemaNameOf(node.schema) orelse return null;
            const schema = item.workspace.schemas().lookup(node.schema) orelse return null;

            if (node.depth == 0) return .{
                .schema = schema,
                .name = spelling,
                .field = null,
                .field_type = .{ .nested = schema.fields },
                .is_element = false,
                .child_count = @intCast(schema.fields.len),
                .index = 0,
            };

            var fields: []const data.Field = schema.fields;
            var current: data.FieldType = .{ .nested = schema.fields };
            var field: ?data.Field = null;
            var is_element = false;
            var index: u32 = 0;
            for (node.path[0..node.depth]) |selector| {
                const item_selector = selector & host_mod.item_selector != 0;
                const position = selector & ~host_mod.item_selector;
                switch (current) {
                    .nested => |declared| {
                        if (item_selector or position >= declared.len) return null;
                        fields = declared;
                        field = declared[position];
                        current = declared[position].type;
                        is_element = false;
                        index = position;
                    },
                    .list => |elem| {
                        // A list declares one element type, so the only position that
                        // names anything is zero.
                        if (!item_selector or position != 0) return null;
                        field = null;
                        current = elem.*;
                        is_element = true;
                        index = 0;
                    },
                    else => return null,
                }
            }

            return .{
                .schema = schema,
                .name = if (field) |f| f.name else "",
                .field = field,
                .field_type = current,
                .is_element = is_element,
                .child_count = switch (current) {
                    .nested => |declared| @intCast(declared.len),
                    // A list has exactly one child in a *declaration* tree: the type of
                    // its elements. Its length is a property of a value, not of a schema.
                    .list => 1,
                    else => 0,
                },
                .index = index,
            };
        }

        pub fn schemaNodeInfo(node: types.SchemaNode, out: ?*author_types.SchemaNodeInfo) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const resolved = a.host.authorSchemaNode(node) orelse return .invalid_handle;
            const site = schemaSiteOf(a, resolved) orelse return .invalid_handle;

            slot.* = .{
                .name = .from(site.name),
                .schema = if (resolved.depth == 0) site.schema.id else .{ .hash = 0 },
                .field_type = @intFromEnum(types.FieldType.fromData(site.field_type)),
                .presence = @intFromEnum(author_types.Presence.fromData(if (site.field) |f| f.presence else null)),
                .child_count = site.child_count,
                .since = if (site.field) |f| f.since else 0,
                .version = if (resolved.depth == 0) site.schema.version else 0,
                .index = site.index,
                .is_root = types.boolOut(resolved.depth == 0),
                .has_default = types.boolOut(if (site.field) |f| f.presence == .default else false),
                .is_list_element = types.boolOut(site.is_element),
            };
            return .ok;
        }

        pub fn schemaNodeChild(node: types.SchemaNode, index: u32, out: ?*types.SchemaNode) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const resolved = a.host.authorSchemaNode(node) orelse return .invalid_handle;
            const site = schemaSiteOf(a, resolved) orelse return .invalid_handle;
            if (index >= site.child_count) return .not_found;
            if (resolved.depth >= host_mod.max_author_path) return .limit;

            var child = resolved;
            child.path[resolved.depth] = switch (site.field_type) {
                .list => host_mod.item_selector,
                else => index,
            };
            child.depth = resolved.depth + 1;
            slot.* = a.host.issueAuthorSchemaNode(child);
            return .ok;
        }

        pub fn schemaNodeDefault(node: types.SchemaNode, out: ?*types.SourceNode) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const resolved = a.host.authorSchemaNode(node) orelse return .invalid_handle;
            const site = schemaSiteOf(a, resolved) orelse return .invalid_handle;
            const field = site.field orelse return .not_found;
            if (field.presence != .default) return .not_found;

            // A default is a value the *schema* owns, so a node over it needs no reader:
            // the registry outlives every handle this issues, and the value with it.
            var value_node: H.AuthorNode = .{
                .workspace = resolved.workspace,
                .root = .default,
                .container = 0,
                .record = site.schema.id.hash,
                .depth = resolved.depth,
            };
            @memcpy(value_node.path[0..resolved.depth], resolved.path[0..resolved.depth]);
            slot.* = a.host.issueAuthorNode(value_node);
            return .ok;
        }

        // -- Source, dependency and preview trees -----------------------------------

        pub fn recordNext(document: types.Document, cursor: ?*Cursor, out: ?*types.SourceNode) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const located = a.document(document) orelse return .invalid_handle;

            const probe: H.AuthorNode = .{
                .workspace = located.handle.unwrap(author.ServiceHandle),
                .root = .source,
                .container = located.index,
                .record = 0,
            };
            const reader = sourceReader(a, located, probe) catch |err| return editResult(err);
            const count = reader.source.count();
            const expected = generation(a, count, salt_record);
            var at = walk(c, expected, count) orelse return .refused;

            // Imported declarations belong to the file they were written in; a walk of
            // *this* document hands back the ones this document declares (`editor.md` §5).
            while (at < count) : (at += 1) {
                if (!reader.source.isLocalAt(@intCast(at))) continue;
                const declaration = reader.source.declarationAt(@intCast(at)).?;
                if (declaration.kind != .define) continue;
                var node = probe;
                node.record = at;
                slot.* = a.host.issueAuthorNode(node);
                advance(c, expected, at + 1);
                return .ok;
            }
            advance(c, expected, count);
            return .end;
        }

        pub fn dependencyNext(workspace: types.Workspace, cursor: ?*Cursor, out: ?*author_types.PackageInfo) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const item = a.entry(workspace) orelse return .invalid_handle;

            const packages = item.workspace.dependencies.items();
            const expected = generation(a, packages.len, salt_dependency);
            const at = walk(c, expected, packages.len) orelse return .refused;
            if (at >= packages.len) return .end;

            const package = &packages[at];
            slot.* = .{
                .name = .from(package.name()),
                .path = .from(package.path),
                .id = package.id(),
                .version = package.version(),
                .record_count = recordCountOf(package),
                .index = @intCast(at),
            };
            advance(c, expected, at + 1);
            return .ok;
        }

        fn recordCountOf(package: *const author.dependency.Package) u32 {
            var count: u32 = 0;
            while (package.reader.record(count) != null) count += 1;
            return count;
        }

        pub fn dependencyRecordNext(
            workspace: types.Workspace,
            package_index: u32,
            cursor: ?*Cursor,
            out: ?*types.SourceNode,
        ) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const item = a.entry(workspace) orelse return .invalid_handle;

            const packages = item.workspace.dependencies.items();
            if (package_index >= packages.len) return .not_found;
            const count = recordCountOf(&packages[package_index]);
            const expected = generation(a, count, salt_dependency_record);
            const at = walk(c, expected, count) orelse return .refused;
            if (at >= count) return .end;

            slot.* = a.host.issueAuthorNode(.{
                .workspace = workspace.unwrap(author.ServiceHandle),
                .root = .dependency,
                .container = package_index,
                .record = at,
            });
            advance(c, expected, at + 1);
            return .ok;
        }

        pub fn previewRecordNext(workspace: types.Workspace, cursor: ?*Cursor, out: ?*types.SourceNode) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const item = a.entry(workspace) orelse return .invalid_handle;
            if (item.preview_grant == null) return .unavailable;
            const store = item.preview.store orelse return .not_found;

            const order = store.sequence.items;
            const expected = generation(a, order.len, salt_preview);
            const at = walk(c, expected, order.len) orelse return .refused;
            if (at >= order.len) return .end;

            slot.* = a.host.issueAuthorNode(.{
                .workspace = workspace.unwrap(author.ServiceHandle),
                .root = .preview,
                .container = 0,
                .record = order[at].bits(),
            });
            advance(c, expected, at + 1);
            return .ok;
        }

        // -- Node reading -----------------------------------------------------------

        /// Opens or reuses the parse behind a source node.
        fn sourceReader(a: Active, located: Located, node: H.AuthorNode) author.EditError!*H.AuthorReader {
            var key = node;
            // One reader per file, not per record: a form drawing a package's records
            // would otherwise reparse the file once per row.
            key.record = 0;
            if (a.host.authorReader(key)) |open| return open;

            located.entry.begin(a.service.gpa);
            var inspection = try located.entry.workspace.openDocument(located.index, &located.entry.diags);
            located.entry.end(located.entry.workspace.revision());
            errdefer inspection.deinit();

            const reader = a.host.openAuthorReader(key);
            reader.kind = .source;
            reader.source = inspection;
            return reader;
        }

        /// Opens or reuses the exact-value snapshot behind a dependency or preview node.
        fn storedReader(a: Active, item: *author.service.Entry, node: H.AuthorNode) !*H.AuthorReader {
            if (a.host.authorReader(node)) |open| return open;

            var record: author.snapshot.Record = switch (node.root) {
                .dependency => blk: {
                    const packages = item.workspace.dependencies.items();
                    if (node.container >= packages.len) return error.RecordInvalid;
                    break :blk try author.snapshot.ofDependency(a.service.gpa, &packages[node.container], @intCast(node.record));
                },
                .preview => blk: {
                    const store = item.preview.store orelse return error.RecordInvalid;
                    const handle = author.StoreRecordHandle.fromBits(node.record);
                    const found = store.get(handle) orelse return error.RecordInvalid;
                    break :blk try author.snapshot.ofStore(a.service.gpa, store, found);
                },
                else => return error.RecordInvalid,
            };
            errdefer record.deinit();

            const reader = a.host.openAuthorReader(node);
            reader.kind = .stored;
            reader.stored = record;
            return reader;
        }

        /// Everything a node read needs, whichever root it came from.
        const Site = struct {
            info: author.snapshot.NodeInfo,
            /// What the *record* is, for a root node's identity fields.
            record_id: ContentId = .none,
            record_schema: data.SchemaId = .{ .hash = 0 },
            /// Where an id value's spelling is looked up.
            spellings: Spellings,
            writable: bool,
        };

        const Spellings = union(enum) {
            /// Every identifier the parse saw, by hash.
            document: *const data.Document,
            /// A compiled package's own recoverable spellings: its name, its schemas' and
            /// its records'. An id naming anything else is deliberately unspellable.
            package: *const data.fpk.Reader,
            none,

            fn lookup(self: Spellings, id: ContentId) ?[]const u8 {
                return switch (self) {
                    .document => |doc| doc.stringOf(id.hash),
                    .package => |reader| spellingIn(reader, id),
                    .none => null,
                };
            }
        };

        fn spellingIn(reader: *const data.fpk.Reader, id: ContentId) ?[]const u8 {
            var index: u32 = 0;
            while (reader.record(index)) |record| : (index += 1) {
                if (record.id.eql(id)) return record.name;
            }
            return null;
        }

        fn siteOf(a: Active, node: H.AuthorNode) ?Site {
            const item = a.service.entry(node.workspace) orelse return null;
            const path = selectorsOf(node) orelse return null;

            switch (node.root) {
                .source => {
                    if (node.container >= item.workspace.documents.len) return null;
                    const located: Located = .{
                        .handle = .{ .bits = node.workspace.bits() },
                        .entry = item,
                        .index = node.container,
                    };
                    const reader = sourceReader(a, located, node) catch return null;
                    const declaration = reader.source.declarationAt(@intCast(node.record)) orelse return null;
                    const info = reader.source.nodeIn(@intCast(node.record), path) catch return null;
                    return .{
                        .info = info,
                        .record_id = declaration.id,
                        .record_schema = declaration.schema,
                        .spellings = .{ .document = &reader.source.document },
                        .writable = item.workspace.documents[node.container].editable and item.workspace.grants.edit,
                    };
                },
                .dependency, .preview => {
                    const reader = storedReader(a, item, node) catch return null;
                    const info = reader.stored.node(path) orelse return null;
                    const spellings: Spellings = switch (node.root) {
                        .dependency => blk: {
                            const packages = item.workspace.dependencies.items();
                            if (node.container >= packages.len) break :blk .none;
                            break :blk .{ .package = &packages[node.container].reader };
                        },
                        else => .none,
                    };
                    return .{
                        .info = info,
                        .record_id = reader.stored.id,
                        .record_schema = reader.stored.schema_id,
                        .spellings = spellings,
                        .writable = false,
                    };
                },
                .default => {
                    const schema = item.workspace.schemas().lookup(.{ .hash = node.record }) orelse return null;
                    const site = defaultSite(schema.*, path) orelse return null;
                    return .{ .info = site, .spellings = .none, .writable = false };
                },
            }
        }

        /// A schema default, walked as a value. The declaration's path locates the field;
        /// its default is the value, and everything below it is an ordinary value walk.
        fn defaultSite(schema: data.Schema, path: []const Selector) ?author.snapshot.NodeInfo {
            var fields: []const data.Field = schema.fields;
            var field: ?data.Field = null;
            var at: usize = 0;
            while (at < path.len) : (at += 1) {
                const index = switch (path[at]) {
                    .field => |i| i,
                    .item => break,
                };
                if (index >= fields.len) return null;
                field = fields[index];
                switch (fields[index].type) {
                    .nested => |declared| fields = declared,
                    else => {
                        at += 1;
                        break;
                    },
                }
            }
            const declared = field orelse return null;
            const default = switch (declared.presence) {
                .default => |value| value,
                else => return null,
            };
            if (at >= path.len) return .{
                .name = declared.name,
                .field_type = declared.type,
                .presence = declared.presence,
                .authored = true,
                .child_count = author.snapshot.childCount(declared.type, default),
                .value = default,
            };
            // Below the field the default belongs to, it is just a value tree.
            const values = [_]?Value{default};
            const one = [_]data.Field{declared};
            return author.snapshot.walk(&one, &values, path[at - 1 ..]);
        }

        fn selectorsOf(node: H.AuthorNode) ?[]const Selector {
            const S = struct {
                threadlocal var buffer: [host_mod.max_author_path]Selector = @splat(.{ .field = 0 });
            };
            if (node.depth > host_mod.max_author_path) return null;
            for (node.path[0..node.depth], 0..) |packed_selector, i| {
                S.buffer[i] = if (packed_selector & host_mod.item_selector != 0)
                    .{ .item = packed_selector & ~host_mod.item_selector }
                else
                    .{ .field = packed_selector };
            }
            return S.buffer[0..node.depth];
        }

        pub fn nodeInfo(node: types.SourceNode, out: ?*author_types.NodeInfo) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const resolved = a.host.authorNode(node) orelse return .invalid_handle;
            const site = siteOf(a, resolved) orelse return .invalid_handle;
            const root = resolved.depth == 0;

            slot.* = .{
                .name = .from(site.info.name),
                .id = if (root) site.record_id else .none,
                .schema = if (root) site.record_schema else .{ .hash = 0 },
                .field_type = @intFromEnum(types.FieldType.fromData(site.info.field_type)),
                .presence = @intFromEnum(author_types.Presence.fromData(site.info.presence)),
                .child_count = site.info.child_count,
                .index = if (resolved.depth == 0) 0 else resolved.path[resolved.depth - 1] & ~host_mod.item_selector,
                .root = @intFromEnum(resolved.root),
                .container = resolved.container,
                .authored = types.boolOut(site.info.authored),
                .is_root = types.boolOut(root),
                .is_list = types.boolOut(site.info.field_type == .list),
                .writable = types.boolOut(site.writable),
                .depth = resolved.depth,
            };
            return .ok;
        }

        pub fn nodeChild(node: types.SourceNode, index: u32, out: ?*types.SourceNode) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const resolved = a.host.authorNode(node) orelse return .invalid_handle;
            const site = siteOf(a, resolved) orelse return .invalid_handle;
            if (index >= site.info.child_count) return .not_found;
            if (resolved.depth >= host_mod.max_author_path) return .limit;

            var child = resolved;
            child.path[resolved.depth] = switch (site.info.field_type) {
                .list => index | host_mod.item_selector,
                else => index,
            };
            child.depth = resolved.depth + 1;
            slot.* = a.host.issueAuthorNode(child);
            return .ok;
        }

        pub fn nodeField(node: types.SourceNode, name: Str, out: ?*types.SourceNode) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const text = name.utf8() orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const resolved = a.host.authorNode(node) orelse return .invalid_handle;
            const site = siteOf(a, resolved) orelse return .invalid_handle;
            const fields = switch (site.info.field_type) {
                .nested => |declared| declared,
                else => return .unsupported,
            };
            if (resolved.depth >= host_mod.max_author_path) return .limit;

            for (fields, 0..) |field, i| {
                if (!std.mem.eql(u8, field.name, text)) continue;
                var child = resolved;
                child.path[resolved.depth] = @intCast(i);
                child.depth = resolved.depth + 1;
                slot.* = a.host.issueAuthorNode(child);
                return .ok;
            }
            return .not_found;
        }

        pub fn nodeScalar(node: types.SourceNode, out: ?*author_types.Value) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const resolved = a.host.authorNode(node) orelse return .invalid_handle;
            const site = siteOf(a, resolved) orelse return .invalid_handle;

            const field_type = @intFromEnum(types.FieldType.fromData(site.info.field_type));
            const value = site.info.value orelse {
                // Not an error: absent is one of the three states, and `authored` on the
                // node info is where a client learns which one this is.
                slot.* = .{ .field_type = field_type };
                return .ok;
            };

            switch (value) {
                .bool => |b| slot.* = .{ .field_type = field_type, .boolean = types.boolOut(b) },
                .string => |text| slot.* = .{ .field_type = field_type, .text = .from(text) },
                .id => |id| slot.* = .{
                    .field_type = field_type,
                    .id = id,
                    .text = if (site.spellings.lookup(id)) |spelling| .from(spelling) else .empty,
                },
                .int, .float => {
                    const text = formatScalar(a.host, site.info.field_type, value) orelse return .internal;
                    slot.* = .{ .field_type = field_type, .text = .from(text) };
                },
                // A container is not a scalar, and saying so is more use than an empty
                // string that looks like an answer.
                .list, .nested => return .unsupported,
            }
            return .ok;
        }

        /// One number, in the spelling an emission would write, into the host's scratch.
        ///
        /// `data.emit` rather than a `{d}` of our own, and that is the point: what a client
        /// reads back is byte-for-byte what a Save would put in the file, so a round trip
        /// through a form changes nothing.
        fn formatScalar(host: *H, field_type: data.FieldType, value: Value) ?[]const u8 {
            // The emitter appends through an allocator, so it gets a scratch buffer with
            // room for a list to grow in; the answer is then copied into the host's, which
            // is the storage the borrow actually points at.
            var scratch: [1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&scratch);
            var out: std.ArrayList(u8) = .empty;
            data.emit.writeValue(&out, fba.allocator(), .{ .spellings = &no_spellings }, field_type, value) catch return null;
            if (out.items.len > host.author_text.len) return null;
            @memcpy(host.author_text[0..out.items.len], out.items);
            return host.author_text[0..out.items.len];
        }

        pub fn nodeCopyText(
            node: types.SourceNode,
            buffer: ?[*]u8,
            capacity: u64,
            needed: ?*u64,
        ) callconv(.c) Result {
            var value: author_types.Value = .{};
            const code = nodeScalar(node, &value);
            if (code != .ok) return code;
            return copyOut(value.text.bytes() orelse &.{}, buffer, capacity, needed);
        }

        fn copyOut(bytes: []const u8, buffer: ?[*]u8, capacity: u64, needed: ?*u64) Result {
            if (needed) |n| n.* = bytes.len;
            if (capacity == 0) return if (bytes.len == 0) .ok else .limit;
            const into = buffer orelse return .invalid_argument;
            if (bytes.len > capacity) return .limit;
            @memcpy(into[0..bytes.len], bytes);
            return .ok;
        }

        // -- Commands ---------------------------------------------------------------

        /// What every command does after it succeeds: stamp the diagnostics, move the
        /// service's generation so outstanding nodes refuse, drop the open parses, and
        /// re-resolve the selection the service asked for.
        fn finish(
            a: Active,
            item: *author.service.Entry,
            workspace: types.Workspace,
            result: author.EditResult,
            out: *author_types.Edit,
        ) Result {
            item.end(result.revision);
            a.service.moved();
            a.host.changedAuthoring();

            out.* = .{
                .revision = result.revision,
                .document = H.authorDocumentHandle(workspace.unwrap(author.ServiceHandle), result.selection.document) orelse .none,
                .record = result.selection.record orelse .none,
                .has_record = types.boolOut(result.selection.record != null),
            };

            // The selection is a record id and a path; a node handle needs the record's
            // index, which means finding it in the document the command touched. Failing
            // to is not a failure of the command — the record may have been deleted — so
            // the handle is simply null.
            const id = result.selection.record orelse return .ok;
            if (result.selection.document >= item.workspace.documents.len) return .ok;
            if (result.selection.path.len > host_mod.max_author_path) return .ok;
            const located: Located = .{ .handle = workspace, .entry = item, .index = result.selection.document };
            const probe: H.AuthorNode = .{
                .workspace = workspace.unwrap(author.ServiceHandle),
                .root = .source,
                .container = result.selection.document,
                .record = 0,
            };
            const reader = sourceReader(a, located, probe) catch return .ok;
            var index: u32 = 0;
            while (index < reader.source.count()) : (index += 1) {
                if (!reader.source.isLocalAt(index)) continue;
                const declaration = reader.source.declarationAt(index).?;
                if (!declaration.id.eql(id)) continue;
                var node = probe;
                node.record = index;
                node.depth = @intCast(result.selection.path.len);
                for (result.selection.path, 0..) |selector, i| {
                    node.path[i] = switch (selector) {
                        .field => |f| f,
                        .item => |e| e | host_mod.item_selector,
                    };
                }
                out.selection = a.host.issueAuthorNode(node);
                return .ok;
            }
            return .ok;
        }

        pub fn recordCreate(
            document: types.Document,
            expected_revision: u64,
            schema: Str,
            id: Str,
            out: ?*author_types.Edit,
        ) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const schema_text = schema.utf8() orelse return .invalid_argument;
            const id_text = id.utf8() orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const located = a.document(document) orelse return .invalid_handle;

            located.entry.begin(a.service.gpa);
            const result = located.entry.workspace.createRecord(expected_revision, located.index, schema_text, id_text, &located.entry.diags) catch |err| return editResult(err);
            return finish(a, located.entry, located.handle, result, slot);
        }

        pub fn recordDuplicate(
            node: types.SourceNode,
            destination: types.Document,
            expected_revision: u64,
            id: Str,
            out: ?*author_types.Edit,
        ) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const id_text = id.utf8() orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const resolved = a.host.authorNode(node) orelse return .invalid_handle;
            const located = a.document(destination) orelse return .invalid_handle;
            if (resolved.root != .source or resolved.depth != 0) return .invalid_argument;
            if (!resolved.workspace.eql(located.handle.unwrap(author.ServiceHandle))) return .invalid_argument;

            located.entry.begin(a.service.gpa);
            const result = located.entry.workspace.duplicateRecord(
                expected_revision,
                .{ .document = resolved.container, .record = @intCast(resolved.record) },
                located.index,
                id_text,
                &located.entry.diags,
            ) catch |err| return editResult(err);
            return finish(a, located.entry, located.handle, result, slot);
        }

        pub fn recordOverride(
            node: types.SourceNode,
            destination: types.Document,
            expected_revision: u64,
            out: ?*author_types.Edit,
        ) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const resolved = a.host.authorNode(node) orelse return .invalid_handle;
            const located = a.document(destination) orelse return .invalid_handle;
            // Only a whole dependency definition can be overridden: an override is a copy
            // of a record, not of one of its fields (`editor.md` §5).
            if (resolved.root != .dependency or resolved.depth != 0) return .invalid_argument;
            if (!resolved.workspace.eql(located.handle.unwrap(author.ServiceHandle))) return .invalid_argument;

            located.entry.begin(a.service.gpa);
            const result = located.entry.workspace.createOverride(
                expected_revision,
                located.index,
                .{ .package = resolved.container, .record = @intCast(resolved.record) },
                &located.entry.diags,
            ) catch |err| return editResult(err);
            return finish(a, located.entry, located.handle, result, slot);
        }

        pub fn recordDelete(node: types.SourceNode, expected_revision: u64, out: ?*author_types.Edit) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const resolved = a.host.authorNode(node) orelse return .invalid_handle;
            if (resolved.root != .source or resolved.depth != 0) return .invalid_argument;
            const item = a.service.entry(resolved.workspace) orelse return .invalid_handle;
            const workspace: types.Workspace = .{ .bits = resolved.workspace.bits() };

            item.begin(a.service.gpa);
            const result = item.workspace.deleteRecord(
                expected_revision,
                .{ .document = resolved.container, .record = @intCast(resolved.record) },
                &item.diags,
            ) catch |err| return editResult(err);
            return finish(a, item, workspace, result, slot);
        }

        /// A caller's scalar, turned into the value the command takes.
        ///
        /// The declared type decides how the text is read, and the text is all there is:
        /// there is no binary path for a number here, so there is no way for one to
        /// disagree with the other.
        /// A field type from the other side, which may be any `i32` at all. Looked up
        /// rather than cast: an enum-typed value holding a number the enum does not have
        /// is illegal in Zig before any validation could run.
        fn fieldTypeOf(code: i32) ?types.FieldType {
            inline for (@typeInfo(types.FieldType).@"enum".fields) |field| {
                if (field.value == code) return @field(types.FieldType, field.name);
            }
            return null;
        }

        fn typedValueOf(supplied: *const author_types.Value, spelling: *[]const u8) ?author.TypedValue {
            const kind = fieldTypeOf(supplied.field_type) orelse return null;
            const text = supplied.text.utf8() orelse return null;
            const value: Value = switch (kind) {
                .bool => .{ .bool = types.boolIn(supplied.boolean) },
                .i32, .i64, .u32, .u64 => .{ .int = std.fmt.parseInt(i128, text, 10) catch return null },
                .f32, .f64 => .{ .float = std.fmt.parseFloat(f64, text) catch return null },
                .string => .{ .string = text },
                .id => .{ .id = data.contentId(text) catch return null },
                // An empty container: what "add the optional nested block" and "start a
                // list" mean as one command each, rather than as a special call.
                .nested => .{ .nested = &.{} },
                .list => .{ .list = &.{} },
            };
            if (kind == .id) {
                spelling.* = text;
                return .{ .value = value, .id_spellings = spelling[0..1] };
            }
            return .{ .value = value };
        }

        /// A value command's shared preamble: resolve the node, refuse a read-only root,
        /// and hand back everything the command needs.
        const Target = struct {
            item: *author.service.Entry,
            workspace: types.Workspace,
            ref: author.RecordRef,
            path: []const Selector,
        };

        fn targetOf(a: Active, node: types.SourceNode, want_depth: enum { any, below_root }) ?Target {
            const resolved = a.host.authorNode(node) orelse return null;
            if (resolved.root != .source) return null;
            if (want_depth == .below_root and resolved.depth == 0) return null;
            const item = a.service.entry(resolved.workspace) orelse return null;
            const path = selectorsOf(resolved) orelse return null;
            return .{
                .item = item,
                .workspace = .{ .bits = resolved.workspace.bits() },
                .ref = .{ .document = resolved.container, .record = @intCast(resolved.record) },
                .path = path,
            };
        }

        pub fn valueSet(
            node: types.SourceNode,
            expected_revision: u64,
            value: ?*const author_types.Value,
            out: ?*author_types.Edit,
        ) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const supplied = value orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const target = targetOf(a, node, .below_root) orelse return .invalid_handle;

            var spelling: []const u8 = "";
            const typed = typedValueOf(supplied, &spelling) orelse return .invalid_argument;

            target.item.begin(a.service.gpa);
            const result = target.item.workspace.setValue(expected_revision, target.ref, target.path, typed, &target.item.diags) catch |err| return editResult(err);
            return finish(a, target.item, target.workspace, result, slot);
        }

        pub fn valueUnset(node: types.SourceNode, expected_revision: u64, out: ?*author_types.Edit) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const target = targetOf(a, node, .below_root) orelse return .invalid_handle;

            target.item.begin(a.service.gpa);
            const result = target.item.workspace.unsetField(expected_revision, target.ref, target.path, &target.item.diags) catch |err| return editResult(err);
            return finish(a, target.item, target.workspace, result, slot);
        }

        pub fn listInsert(
            node: types.SourceNode,
            expected_revision: u64,
            index: u32,
            value: ?*const author_types.Value,
            out: ?*author_types.Edit,
        ) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const supplied = value orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const target = targetOf(a, node, .below_root) orelse return .invalid_handle;

            var spelling: []const u8 = "";
            const typed = typedValueOf(supplied, &spelling) orelse return .invalid_argument;

            target.item.begin(a.service.gpa);
            const result = target.item.workspace.insertListItem(expected_revision, target.ref, target.path, index, typed, &target.item.diags) catch |err| return editResult(err);
            return finish(a, target.item, target.workspace, result, slot);
        }

        pub fn listRemove(node: types.SourceNode, expected_revision: u64, index: u32, out: ?*author_types.Edit) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const target = targetOf(a, node, .below_root) orelse return .invalid_handle;

            target.item.begin(a.service.gpa);
            const result = target.item.workspace.removeListItem(expected_revision, target.ref, target.path, index, &target.item.diags) catch |err| return editResult(err);
            return finish(a, target.item, target.workspace, result, slot);
        }

        pub fn listMove(
            node: types.SourceNode,
            expected_revision: u64,
            from: u32,
            to: u32,
            out: ?*author_types.Edit,
        ) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const target = targetOf(a, node, .below_root) orelse return .invalid_handle;

            target.item.begin(a.service.gpa);
            const result = target.item.workspace.moveListItem(expected_revision, target.ref, target.path, from, to, &target.item.diags) catch |err| return editResult(err);
            return finish(a, target.item, target.workspace, result, slot);
        }

        pub fn undo(workspace: types.Workspace, expected_revision: u64, out: ?*author_types.Edit) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const item = a.entry(workspace) orelse return .invalid_handle;
            item.begin(a.service.gpa);
            const result = item.workspace.undo(expected_revision, &item.diags) catch |err| return editResult(err);
            return finish(a, item, workspace, result, slot);
        }

        pub fn redo(workspace: types.Workspace, expected_revision: u64, out: ?*author_types.Edit) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const item = a.entry(workspace) orelse return .invalid_handle;
            item.begin(a.service.gpa);
            const result = item.workspace.redo(expected_revision, &item.diags) catch |err| return editResult(err);
            return finish(a, item, workspace, result, slot);
        }

        // -- Persistence -------------------------------------------------------------

        pub fn saveDocument(
            document: types.Document,
            expected_revision: u64,
            out: ?*author_types.SaveResult,
        ) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const located = a.document(document) orelse return .invalid_handle;
            const item = located.entry;

            item.begin(a.service.gpa);
            const result = item.workspace.saveDocument(expected_revision, located.index, &item.diags) catch |err| return saveResultCode(err);
            item.end(result.revision);
            a.service.moved();
            a.host.changedAuthoring();

            slot.* = .{
                .revision = result.revision,
                .document = document,
                .outcome = @intFromEnum(if (result.published) author_types.SaveOutcome.published else .unchanged),
                .failure = @intFromEnum(author_types.SaveFailure.none),
                .durable = types.boolOut(result.durability == .durable),
                .lock_released = types.boolOut(result.lock_released),
            };
            return .ok;
        }

        pub fn saveAll(workspace: types.Workspace, expected_revision: u64, out: ?*author_types.SaveAll) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const item = a.entry(workspace) orelse return .invalid_handle;

            item.begin(a.service.gpa);
            var result = item.workspace.saveAll(expected_revision, &item.diags) catch |err| return saveResultCode(err);
            defer result.deinit(a.service.gpa);
            item.end(result.revision);
            a.service.moved();
            a.host.changedAuthoring();

            // The run's own record, kept so a client can walk it after the fact: the
            // alternative is a variable-length answer in one call, which this boundary
            // does not have a shape for.
            const entries = result.items();
            const kept = a.service.gpa.alloc(author.save_mod.AllEntry, entries.len) catch return .out_of_memory;
            a.service.gpa.free(item.save_entries);
            @memcpy(kept, entries);
            item.save_entries = kept;
            item.save_entry_count = entries.len;

            var published: u32 = 0;
            var complete = true;
            for (entries) |written| switch (written.outcome) {
                .saved => published += 1,
                .unchanged => {},
                .failed => complete = false,
            };

            slot.* = .{
                .revision = result.revision,
                .entry_count = @intCast(entries.len),
                .published_count = published,
                .lock_released = types.boolOut(result.lock_released),
                .complete = types.boolOut(complete),
            };
            return .ok;
        }

        pub fn saveEntryNext(workspace: types.Workspace, cursor: ?*Cursor, out: ?*author_types.SaveEntry) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const item = a.entry(workspace) orelse return .invalid_handle;

            const count = item.save_entry_count;
            const expected = generation(a, count, salt_save_entry);
            const at = walk(c, expected, count) orelse return .refused;
            if (at >= count) return .end;

            const written = item.save_entries[at];
            if (written.document >= item.workspace.documents.len) return .invalid_handle;
            slot.* = .{
                .path = .from(item.workspace.documents[written.document].path),
                .document = H.authorDocumentHandle(workspace.unwrap(author.ServiceHandle), written.document) orelse .none,
                .outcome = @intFromEnum(switch (written.outcome) {
                    .saved => author_types.SaveOutcome.published,
                    .unchanged => author_types.SaveOutcome.unchanged,
                    .failed => author_types.SaveOutcome.failed,
                }),
                .failure = @intFromEnum(switch (written.outcome) {
                    .failed => |reason| switch (reason) {
                        .external_change => author_types.SaveFailure.external_change,
                        .document_budget => author_types.SaveFailure.document_budget,
                        .io_failed => author_types.SaveFailure.io_failed,
                        .out_of_memory => author_types.SaveFailure.out_of_memory,
                    },
                    else => author_types.SaveFailure.none,
                }),
                .durable = types.boolOut(switch (written.outcome) {
                    .saved => |durability| durability == .durable,
                    else => false,
                }),
            };
            advance(c, expected, at + 1);
            return .ok;
        }

        // -- Diagnostics ---------------------------------------------------------------

        pub fn validate(workspace: types.Workspace, expected_revision: u64) callconv(.c) Result {
            const a = active() orelse return .unavailable;
            const item = a.entry(workspace) orelse return .invalid_handle;

            item.begin(a.service.gpa);
            item.workspace.validate(expected_revision, &item.diags) catch |err| {
                item.end(item.workspace.revision());
                return buildResultCode(err);
            };
            item.end(item.workspace.revision());
            return .ok;
        }

        pub fn diagnosticNext(workspace: types.Workspace, cursor: ?*Cursor, out: ?*author_types.Diagnostic) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const item = a.entry(workspace) orelse return .invalid_handle;

            const entries = item.diags.items.items;
            const expected = generation(a, entries.len, salt_diagnostic);
            const at = walk(c, expected, entries.len) orelse return .refused;
            if (at >= entries.len) return .end;

            const entry = entries[at];
            slot.* = .{
                .revision = item.diags_revision,
                .file = .from(entry.location.file),
                .message = .from(entry.message),
                .source_line = .from(entry.source_line),
                .note = if (entry.note) |n| .from(n.message) else .empty,
                .note_file = if (entry.note) |n| .from(n.location.file) else .empty,
                .line = entry.location.line,
                .column = entry.location.column,
                .length = entry.length,
                .severity = @intFromEnum(author_types.Severity.fromData(entry.severity)),
                .note_line = if (entry.note) |n| n.location.line else 0,
                .note_column = if (entry.note) |n| n.location.column else 0,
                .suppressed = item.diags.suppressed,
                .has_note = types.boolOut(entry.note != null),
            };
            advance(c, expected, at + 1);
            return .ok;
        }

        // -- Products --------------------------------------------------------------

        pub fn build(workspace: types.Workspace, expected_revision: u64, out: ?*types.Build) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const item = a.entry(workspace) orelse return .invalid_handle;

            item.begin(a.service.gpa);
            const handle = item.workspace.build(expected_revision, &item.diags) catch |err| {
                item.end(item.workspace.revision());
                return buildResultCode(err);
            };
            item.end(item.workspace.revision());

            slot.* = a.host.issueAuthorBuild(workspace.unwrap(author.ServiceHandle), handle) orelse {
                // More live builds than this boundary can name. The candidate is real, so
                // it is released rather than leaked behind a handle nobody has.
                item.workspace.releaseBuild(handle, &item.diags) catch {};
                return .limit;
            };
            a.service.moved();
            a.host.changedAuthoring();
            return .ok;
        }

        pub fn buildInfo(handle: types.Build, out: ?*author_types.BuildInfo) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const resolved = a.host.authorBuild(handle) orelse return .invalid_handle;
            const item = a.service.entry(resolved.workspace) orelse return .invalid_handle;
            const info = item.workspace.buildInfo(resolved.build) catch |err| return buildResultCode(err);
            slot.* = .{
                .revision = info.revision,
                .package_name = .from(info.package_name),
                .package_bytes = info.package_bytes.len,
                .package_version = info.package_version,
            };
            return .ok;
        }

        pub fn buildRelease(handle: types.Build) callconv(.c) Result {
            const a = active() orelse return .unavailable;
            const resolved = a.host.authorBuild(handle) orelse return .invalid_handle;
            const workspace: types.Workspace = .{ .bits = resolved.workspace.bits() };
            _ = workspace;
            a.service.releaseBuild(resolved.workspace, resolved.build) catch |err| return serviceResultCode(err);
            a.host.forgetAuthorBuild(handle);
            a.host.changedAuthoring();
            return .ok;
        }

        pub fn exportNext(workspace: types.Workspace, cursor: ?*Cursor, out: ?*author_types.ExportInfo) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const item = a.entry(workspace) orelse return .invalid_handle;

            const targets = item.exports;
            const expected = generation(a, targets.len, salt_export);
            const at = walk(c, expected, targets.len) orelse return .refused;
            if (at >= targets.len) return .end;

            const target = targets[at];
            slot.* = .{
                .name = .from(target.name),
                .index = @intCast(at),
                .kind = @intFromEnum(switch (target.kind) {
                    .compiled => author_types.ExportKind.compiled,
                    .runtime => author_types.ExportKind.runtime,
                }),
                .has_assets = types.boolOut(target.assets_root != null),
            };
            advance(c, expected, at + 1);
            return .ok;
        }

        pub fn buildExport(handle: types.Build, destination: u32, out: ?*u32) callconv(.c) Result {
            const a = active() orelse return .unavailable;
            const resolved = a.host.authorBuild(handle) orelse return .invalid_handle;
            const written = a.service.exportBuild(resolved.workspace, resolved.build, destination) catch |err| return serviceResultCode(err);
            if (out) |slot| slot.* = written;
            return .ok;
        }

        pub fn previewActivate(handle: types.Build) callconv(.c) Result {
            const a = active() orelse return .unavailable;
            const resolved = a.host.authorBuild(handle) orelse return .invalid_handle;
            a.service.activatePreview(resolved.workspace, resolved.build) catch |err| return serviceResultCode(err);
            a.host.changedAuthoring();
            return .ok;
        }

        pub fn previewInfo(workspace: types.Workspace, out: ?*author_types.PreviewInfo) callconv(.c) Result {
            const slot = out orelse return .invalid_argument;
            const a = active() orelse return .unavailable;
            const item = a.entry(workspace) orelse return .invalid_handle;
            slot.* = .{
                .content_generation = item.preview.content_generation,
                .build_revision = item.preview.revision,
                .build = .none,
                .outcome = @intFromEnum(switch (item.preview.outcome) {
                    .none => author_types.PreviewOutcome.none,
                    .active => author_types.PreviewOutcome.active,
                    .failed => author_types.PreviewOutcome.failed,
                }),
                .available = types.boolOut(item.preview_grant != null),
            };
            return .ok;
        }
    };
}

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;
const platform = @import("platform");
const test_engine = @import("test_engine.zig");
const api = @import("api.zig");

const TestEngine = test_engine.TestEngine;
const Host = host_mod.HostOf(TestEngine);
const table = api.TableOf(Host).v4;

/// A bound host with a real service over a real granted directory.
///
/// Everything below goes through `table`, never through `author` — which is the point of
/// these tests as much as of the boundary: if a capability is only reachable from Zig, the
/// editor cannot have it either (I4).
const Fixture = struct {
    engine: *TestEngine,
    host: *Host,
    service: *author.Service,
    tmp: std.testing.TmpDir,
    base: []const u8 = "",
    base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    owned: std.ArrayList([]const u8) = .empty,
    diags: data.Diagnostics,
    workspace: types.Workspace = .none,

    const manifest_text =
        \\foundry:mod demo:abi {
        \\  name "ABI fixture"
        \\  version 1
        \\  license "Apache-2.0"
        \\}
        \\
    ;

    const schema_text =
        \\@schema demo:item {
        \\    count  u64
        \\    label  string            (default "none")
        \\    weight f64               (optional)
        \\    tags   [string]          (optional)
        \\    where  { x i32  y i32 }  (optional)
        \\}
        \\
    ;

    fn init(options: struct { grants: author.WorkspaceGrants = .{ .edit = true, .save = true, .build = true } }) !*Fixture {
        const gpa = testing.allocator;
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);

        const engine = try gpa.create(TestEngine);
        errdefer gpa.destroy(engine);
        engine.* = try .init(gpa);
        engine.settle();

        self.* = .{
            .engine = engine,
            .host = undefined,
            .service = undefined,
            .tmp = testing.tmpDir(.{}),
            .diags = .init(gpa, .default),
        };
        const n = try self.tmp.dir.realPath(testing.io, &self.base_buf);
        self.base = self.base_buf[0..n];

        try engine.os.createDirPath(try self.at("src"));
        try engine.os.createDirPath(try self.at("out"));
        try self.write("mod.fdt", manifest_text);
        try self.write("items.fdt", schema_text ++
            \\demo:item demo:torch {
            \\  count 3
            \\  tags [ "light" "tool" ]
            \\}
            \\
        );

        const service = try gpa.create(author.Service);
        errdefer gpa.destroy(service);
        service.* = .init(gpa, engine.os, .{});
        self.service = service;

        const host = try gpa.create(Host);
        host.* = .{ .engine = engine, .author_service = service };
        self.host = host;
        host.bind();

        self.workspace = .{ .bits = (try service.open(try self.at("src"), .{ .workspace = .{
            .output_root = try self.at("out"),
            .grants = options.grants,
        } }, &self.diags)).bits() };
        return self;
    }

    fn deinit(self: *Fixture) void {
        const gpa = testing.allocator;
        self.host.unbind();
        self.service.deinit();
        gpa.destroy(self.service);
        gpa.destroy(self.host);
        self.diags.deinit(gpa);
        for (self.owned.items) |path| gpa.free(path);
        self.owned.deinit(gpa);
        self.engine.deinit();
        gpa.destroy(self.engine);
        self.tmp.cleanup();
        gpa.destroy(self);
    }

    fn at(self: *Fixture, rel: []const u8) ![]const u8 {
        const gpa = testing.allocator;
        const path = try platform.os.joinPath(gpa, &.{ self.base, rel });
        errdefer gpa.free(path);
        try self.owned.append(gpa, path);
        return path;
    }

    fn write(self: *Fixture, rel: []const u8, text: []const u8) !void {
        const gpa = testing.allocator;
        const path = try platform.os.joinPath(gpa, &.{ self.base, "src", rel });
        defer gpa.free(path);
        try self.engine.os.writeFile(path, text);
    }

    fn revision(self: *Fixture) !u64 {
        var value: u64 = 0;
        try testing.expectEqual(Result.ok, table.author_workspace_revision(self.workspace, &value));
        return value;
    }

    /// The document whose relative name is `path`, found the way a client finds one.
    fn document(self: *Fixture, path: []const u8) !types.Document {
        var cursor: Cursor = .begin;
        var handle: types.Document = .none;
        while (table.author_document_next(self.workspace, &cursor, &handle) == .ok) {
            var info: author_types.DocumentInfo = .{};
            try testing.expectEqual(Result.ok, table.author_document_info(handle, &info));
            if (std.mem.eql(u8, info.path.bytes().?, path)) return handle;
        }
        return error.TestUnexpectedResult;
    }

    /// The record spelled `name` in that document.
    fn record(self: *Fixture, path: []const u8, name: []const u8) !types.SourceNode {
        const doc = try self.document(path);
        var cursor: Cursor = .begin;
        var node: types.SourceNode = .none;
        while (table.author_record_next(doc, &cursor, &node) == .ok) {
            var info: author_types.NodeInfo = .{};
            try testing.expectEqual(Result.ok, table.author_node_info(node, &info));
            if (std.mem.eql(u8, info.name.bytes().?, name)) return node;
        }
        return error.TestUnexpectedResult;
    }
};

test "a C consumer walks a workspace, its documents and one record's fields" {
    const f = try Fixture.init(.{});
    defer f.deinit();

    var info: author_types.WorkspaceInfo = .{};
    try testing.expectEqual(Result.ok, table.author_workspace_info(f.workspace, &info));
    try testing.expectEqualStrings("demo:abi", info.package_name.bytes().?);
    try testing.expectEqual(@as(u32, 1), info.package_version);
    try testing.expectEqual(@as(u32, 2), info.document_count);
    try testing.expectEqual(@as(u8, 1), info.has_manifest);
    try testing.expectEqual(@as(u8, 1), info.can_edit);
    try testing.expectEqual(@as(u8, 0), info.dirty);
    try testing.expectEqual(@as(u8, 0), info.can_preview);

    // The configured bounds are published rather than guessed at.
    var limits: author_types.Limits = .{};
    try testing.expectEqual(Result.ok, table.author_workspace_limits(f.workspace, &limits));
    try testing.expectEqual(@as(u64, 16 * 1024 * 1024), limits.max_source_bytes);
    try testing.expectEqual(@as(u32, 128), limits.max_history_commands);

    const torch = try f.record("items.fdt", "demo:torch");
    var node: author_types.NodeInfo = .{};
    try testing.expectEqual(Result.ok, table.author_node_info(torch, &node));
    try testing.expectEqual(@as(u8, 1), node.is_root);
    try testing.expectEqual(@as(u8, 1), node.writable);
    try testing.expectEqual(@as(u32, 5), node.child_count);
    try testing.expectEqual(core.ContentId.fromString("demo:torch"), node.id);

    // A `u64` read back as its exact decimal, not through a float.
    var count: types.SourceNode = .none;
    try testing.expectEqual(Result.ok, table.author_node_field(torch, .from("count"), &count));
    var value: author_types.Value = .{};
    try testing.expectEqual(Result.ok, table.author_node_scalar(count, &value));
    try testing.expectEqual(@intFromEnum(types.FieldType.u64), value.field_type);
    try testing.expectEqualStrings("3", value.text.bytes().?);

    // Unset, default and present stay three answers.
    var label: types.SourceNode = .none;
    try testing.expectEqual(Result.ok, table.author_node_field(torch, .from("label"), &label));
    try testing.expectEqual(Result.ok, table.author_node_info(label, &node));
    try testing.expectEqual(@as(u8, 0), node.authored);
    try testing.expectEqual(@intFromEnum(author_types.Presence.default), node.presence);

    var weight: types.SourceNode = .none;
    try testing.expectEqual(Result.ok, table.author_node_field(torch, .from("weight"), &weight));
    try testing.expectEqual(Result.ok, table.author_node_info(weight, &node));
    try testing.expectEqual(@as(u8, 0), node.authored);
    try testing.expectEqual(@intFromEnum(author_types.Presence.optional), node.presence);

    // A list, by position, with its elements.
    var tags: types.SourceNode = .none;
    try testing.expectEqual(Result.ok, table.author_node_field(torch, .from("tags"), &tags));
    try testing.expectEqual(Result.ok, table.author_node_info(tags, &node));
    try testing.expectEqual(@as(u8, 1), node.is_list);
    try testing.expectEqual(@as(u32, 2), node.child_count);

    var second: types.SourceNode = .none;
    try testing.expectEqual(Result.ok, table.author_node_child(tags, 1, &second));
    try testing.expectEqual(Result.ok, table.author_node_scalar(second, &value));
    try testing.expectEqualStrings("tool", value.text.bytes().?);
    try testing.expectEqual(Result.ok, table.author_node_info(second, &node));
    try testing.expectEqual(@intFromEnum(author_types.Presence.element), node.presence);

    // An unwritten optional block still describes the fields it would have.
    var where: types.SourceNode = .none;
    try testing.expectEqual(Result.ok, table.author_node_field(torch, .from("where"), &where));
    try testing.expectEqual(Result.ok, table.author_node_info(where, &node));
    try testing.expectEqual(@as(u32, 2), node.child_count);
    try testing.expectEqual(@as(u8, 0), node.authored);
    var x: types.SourceNode = .none;
    try testing.expectEqual(Result.ok, table.author_node_child(where, 0, &x));
    try testing.expectEqual(Result.ok, table.author_node_info(x, &node));
    try testing.expectEqualStrings("x", node.name.bytes().?);
    try testing.expectEqual(@as(u8, 0), node.authored);

    // A field nobody declared, and a container asked for as a scalar.
    var missing: types.SourceNode = .none;
    try testing.expectEqual(Result.not_found, table.author_node_field(torch, .from("nope"), &missing));
    try testing.expectEqual(Result.unsupported, table.author_node_scalar(tags, &value));
    try testing.expectEqual(Result.not_found, table.author_node_child(tags, 2, &second));
}

test "the schema tree describes fields, defaults and list element types" {
    const f = try Fixture.init(.{});
    defer f.deinit();

    // Every schema an author may write, engine ones included.
    var cursor: Cursor = .begin;
    var seen_item = false;
    var seen_engine = false;
    var node: types.SchemaNode = .none;
    while (table.author_schema_next(f.workspace, &cursor, &node) == .ok) {
        var info: author_types.SchemaNodeInfo = .{};
        try testing.expectEqual(Result.ok, table.author_schema_node_info(node, &info));
        const name = info.name.bytes().?;
        if (std.mem.eql(u8, name, "demo:item")) seen_item = true;
        if (std.mem.eql(u8, name, "foundry:mod")) seen_engine = true;
    }
    try testing.expect(seen_item);
    try testing.expect(seen_engine);

    var item: types.SchemaNode = .none;
    try testing.expectEqual(Result.ok, table.author_schema_find(f.workspace, .from("demo:item"), &item));
    var info: author_types.SchemaNodeInfo = .{};
    try testing.expectEqual(Result.ok, table.author_schema_node_info(item, &info));
    try testing.expectEqual(@as(u8, 1), info.is_root);
    try testing.expectEqual(@as(u32, 5), info.child_count);
    try testing.expectEqual(@intFromEnum(types.FieldType.nested), info.field_type);

    // A defaulted field, and its default as a value a client can read.
    var label: types.SchemaNode = .none;
    try testing.expectEqual(Result.ok, table.author_schema_node_child(item, 1, &label));
    try testing.expectEqual(Result.ok, table.author_schema_node_info(label, &info));
    try testing.expectEqualStrings("label", info.name.bytes().?);
    try testing.expectEqual(@as(u8, 1), info.has_default);
    try testing.expectEqual(@as(u32, 1), info.since);

    var default_node: types.SourceNode = .none;
    try testing.expectEqual(Result.ok, table.author_schema_node_default(label, &default_node));
    var value: author_types.Value = .{};
    try testing.expectEqual(Result.ok, table.author_node_scalar(default_node, &value));
    try testing.expectEqualStrings("none", value.text.bytes().?);

    // A list declares one element type, which is its one child.
    var tags: types.SchemaNode = .none;
    try testing.expectEqual(Result.ok, table.author_schema_node_child(item, 3, &tags));
    try testing.expectEqual(Result.ok, table.author_schema_node_info(tags, &info));
    try testing.expectEqual(@as(u32, 1), info.child_count);
    var element: types.SchemaNode = .none;
    try testing.expectEqual(Result.ok, table.author_schema_node_child(tags, 0, &element));
    try testing.expectEqual(Result.ok, table.author_schema_node_info(element, &info));
    try testing.expectEqual(@as(u8, 1), info.is_list_element);
    try testing.expectEqual(@intFromEnum(types.FieldType.string), info.field_type);

    // A field with no default says so rather than handing one back.
    var count: types.SchemaNode = .none;
    try testing.expectEqual(Result.ok, table.author_schema_node_child(item, 0, &count));
    try testing.expectEqual(Result.not_found, table.author_schema_node_default(count, &default_node));
    try testing.expectEqual(Result.not_found, table.author_schema_find(f.workspace, .from("demo:absent"), &item));
}

test "a command changes the source, moves the revision and stales every old node" {
    const f = try Fixture.init(.{});
    defer f.deinit();

    const torch = try f.record("items.fdt", "demo:torch");
    var count: types.SourceNode = .none;
    try testing.expectEqual(Result.ok, table.author_node_field(torch, .from("count"), &count));

    const before = try f.revision();
    var edit: author_types.Edit = .{};
    try testing.expectEqual(Result.ok, table.author_value_set(count, before, &.{
        .field_type = @intFromEnum(types.FieldType.u64),
        .text = .from("9007199254740993"),
    }, &edit));
    try testing.expect(edit.revision != before);
    try testing.expectEqual(@as(u8, 1), edit.has_record);
    try testing.expectEqual(core.ContentId.fromString("demo:torch"), edit.record);

    // Every node issued before the command is stale, including the one it changed and the
    // record it belongs to (`editor.md` §5).
    var info: author_types.NodeInfo = .{};
    try testing.expectEqual(Result.invalid_handle, table.author_node_info(count, &info));
    try testing.expectEqual(Result.invalid_handle, table.author_node_info(torch, &info));

    // The selection the command handed back is not stale, and it names the field that was
    // changed — which reads as a `u64` no float could have carried.
    try testing.expectEqual(Result.ok, table.author_node_info(edit.selection, &info));
    try testing.expectEqualStrings("count", info.name.bytes().?);
    var value: author_types.Value = .{};
    try testing.expectEqual(Result.ok, table.author_node_scalar(edit.selection, &value));
    try testing.expectEqualStrings("9007199254740993", value.text.bytes().?);

    var selected: types.SourceNode = .none;

    // A stale revision is refused with nothing changed.
    try testing.expectEqual(Result.refused, table.author_value_set(edit.selection, before, &.{
        .field_type = @intFromEnum(types.FieldType.u64),
        .text = .from("4"),
    }, &edit));

    // Undo restores the exact bytes, and Redo puts them back.
    try testing.expectEqual(Result.ok, table.author_undo(f.workspace, try f.revision(), &edit));
    const after_undo = try f.record("items.fdt", "demo:torch");
    try testing.expectEqual(Result.ok, table.author_node_field(after_undo, .from("count"), &selected));
    try testing.expectEqual(Result.ok, table.author_node_scalar(selected, &value));
    try testing.expectEqualStrings("3", value.text.bytes().?);

    try testing.expectEqual(Result.ok, table.author_redo(f.workspace, try f.revision(), &edit));
    const after_redo = try f.record("items.fdt", "demo:torch");
    try testing.expectEqual(Result.ok, table.author_node_field(after_redo, .from("count"), &selected));
    try testing.expectEqual(Result.ok, table.author_node_scalar(selected, &value));
    try testing.expectEqualStrings("9007199254740993", value.text.bytes().?);
}

test "a value the schema does not accept is refused, and the draft is untouched" {
    const f = try Fixture.init(.{});
    defer f.deinit();

    const torch = try f.record("items.fdt", "demo:torch");
    var count: types.SourceNode = .none;
    try testing.expectEqual(Result.ok, table.author_node_field(torch, .from("count"), &count));
    const before = try f.revision();
    var edit: author_types.Edit = .{};

    // Not a number at all, a number no `u64` holds, and a kind the field is not.
    try testing.expectEqual(Result.invalid_argument, table.author_value_set(count, before, &.{
        .field_type = @intFromEnum(types.FieldType.u64),
        .text = .from("three"),
    }, &edit));
    try testing.expectEqual(Result.invalid_argument, table.author_value_set(count, before, &.{
        .field_type = @intFromEnum(types.FieldType.u64),
        .text = .from("-1"),
    }, &edit));
    try testing.expectEqual(Result.invalid_argument, table.author_value_set(count, before, &.{
        .field_type = @intFromEnum(types.FieldType.string),
        .text = .from("three"),
    }, &edit));

    // A field type this build has no number for is garbage, not an illegal enum value.
    try testing.expectEqual(Result.invalid_argument, table.author_value_set(count, before, &.{
        .field_type = 9999,
        .text = .from("3"),
    }, &edit));

    // Nothing moved, and the old value is still there.
    try testing.expectEqual(before, try f.revision());
    var value: author_types.Value = .{};
    try testing.expectEqual(Result.ok, table.author_node_scalar(count, &value));
    try testing.expectEqualStrings("3", value.text.bytes().?);
}

test "a workspace with no write grant reads everything and changes nothing" {
    const f = try Fixture.init(.{ .grants = .{} });
    defer f.deinit();

    var info: author_types.WorkspaceInfo = .{};
    try testing.expectEqual(Result.ok, table.author_workspace_info(f.workspace, &info));
    try testing.expectEqual(@as(u8, 0), info.can_edit);
    try testing.expectEqual(@as(u8, 0), info.can_save);
    try testing.expectEqual(@as(u8, 0), info.can_build);

    // Reading is unaffected: a read-only workspace is how a tool inspects a package.
    const torch = try f.record("items.fdt", "demo:torch");
    var node: author_types.NodeInfo = .{};
    try testing.expectEqual(Result.ok, table.author_node_info(torch, &node));
    try testing.expectEqual(@as(u8, 0), node.writable);

    var count: types.SourceNode = .none;
    try testing.expectEqual(Result.ok, table.author_node_field(torch, .from("count"), &count));

    const revision = try f.revision();
    var edit: author_types.Edit = .{};
    const document = try f.document("items.fdt");
    try testing.expectEqual(Result.refused, table.author_value_set(count, revision, &.{
        .field_type = @intFromEnum(types.FieldType.u64),
        .text = .from("4"),
    }, &edit));
    try testing.expectEqual(Result.refused, table.author_value_unset(count, revision, &edit));
    try testing.expectEqual(Result.refused, table.author_record_delete(torch, revision, &edit));
    try testing.expectEqual(Result.refused, table.author_record_create(document, revision, .from("demo:item"), .from("demo:lamp"), &edit));
    try testing.expectEqual(Result.refused, table.author_undo(f.workspace, revision, &edit));

    var save: author_types.SaveResult = .{};
    try testing.expectEqual(Result.refused, table.author_save_document(document, revision, &save));
    var built: types.Build = .none;
    try testing.expectEqual(Result.refused, table.author_build(f.workspace, revision, &built));

    // And nothing moved.
    try testing.expectEqual(revision, try f.revision());
}

test "save, validate and build go through the table, and a build exports where the host said" {
    const f = try Fixture.init(.{});
    defer f.deinit();

    const document = try f.document("items.fdt");
    const torch = try f.record("items.fdt", "demo:torch");
    var count: types.SourceNode = .none;
    try testing.expectEqual(Result.ok, table.author_node_field(torch, .from("count"), &count));

    var edit: author_types.Edit = .{};
    try testing.expectEqual(Result.ok, table.author_value_set(count, try f.revision(), &.{
        .field_type = @intFromEnum(types.FieldType.u64),
        .text = .from("11"),
    }, &edit));

    // A build refuses a dirty source, which is the same rule the editor's button obeys.
    var built: types.Build = .none;
    try testing.expectEqual(Result.refused, table.author_build(f.workspace, try f.revision(), &built));

    var save: author_types.SaveResult = .{};
    try testing.expectEqual(Result.ok, table.author_save_document(document, try f.revision(), &save));
    try testing.expectEqual(@intFromEnum(author_types.SaveOutcome.published), save.outcome);
    try testing.expectEqual(@as(u8, 1), save.lock_released);

    // Saving the same bytes again publishes nothing and says so.
    try testing.expectEqual(Result.ok, table.author_save_document(document, try f.revision(), &save));
    try testing.expectEqual(@intFromEnum(author_types.SaveOutcome.unchanged), save.outcome);

    try testing.expectEqual(Result.ok, table.author_validate(f.workspace, try f.revision()));
    try testing.expectEqual(Result.ok, table.author_build(f.workspace, try f.revision(), &built));

    var info: author_types.BuildInfo = .{};
    try testing.expectEqual(Result.ok, table.author_build_info(built, &info));
    try testing.expectEqualStrings("demo:abi", info.package_name.bytes().?);
    try testing.expect(info.package_bytes > 0);

    // A host that configured no destination has none to offer, and a number naming one
    // that does not exist is refused rather than becoming a path.
    var cursor: Cursor = .begin;
    var destination: author_types.ExportInfo = .{};
    try testing.expectEqual(Result.end, table.author_export_next(f.workspace, &cursor, &destination));
    try testing.expectEqual(Result.unsupported, table.author_build_export(built, 0, null));

    // Preview is unavailable without the host's callback, and everything else still works.
    try testing.expectEqual(Result.unavailable, table.author_preview_activate(built));
    var preview: author_types.PreviewInfo = .{};
    try testing.expectEqual(Result.ok, table.author_preview_info(f.workspace, &preview));
    try testing.expectEqual(@as(u8, 0), preview.available);
    try testing.expectEqual(@intFromEnum(author_types.PreviewOutcome.none), preview.outcome);

    try testing.expectEqual(Result.ok, table.author_build_release(built));
    try testing.expectEqual(Result.invalid_handle, table.author_build_info(built, &info));
}

test "a failed validation leaves diagnostics a client can read without a log" {
    const f = try Fixture.init(.{});
    defer f.deinit();

    const document = try f.document("items.fdt");
    var edit: author_types.Edit = .{};
    // A duplicate id, which the workspace refuses and explains.
    try testing.expectEqual(
        Result.already_exists,
        table.author_record_create(document, try f.revision(), .from("demo:item"), .from("demo:torch"), &edit),
    );

    var cursor: Cursor = .begin;
    var entry: author_types.Diagnostic = .{};
    var found = false;
    while (table.author_diagnostic_next(f.workspace, &cursor, &entry) == .ok) {
        if (entry.message.bytes()) |message| {
            if (std.mem.indexOf(u8, message, "demo:torch") != null) found = true;
        }
        try testing.expectEqual(@intFromEnum(author_types.Severity.err), entry.severity);
    }
    try testing.expect(found);

    var info: author_types.WorkspaceInfo = .{};
    try testing.expectEqual(Result.ok, table.author_workspace_info(f.workspace, &info));
    try testing.expect(info.diagnostic_count > 0);
}

test "a document is created, its source is copied out, and a bad name is refused" {
    const f = try Fixture.init(.{});
    defer f.deinit();

    var created: types.Document = .none;
    try testing.expectEqual(Result.ok, table.author_document_create(f.workspace, try f.revision(), .from("extra.fdt"), &created));

    var info: author_types.DocumentInfo = .{};
    try testing.expectEqual(Result.ok, table.author_document_info(created, &info));
    try testing.expectEqualStrings("extra.fdt", info.path.bytes().?);
    try testing.expectEqual(@as(u8, 0), info.on_disk);

    // A name that escapes the granted root, one that is not a source file, and one that
    // already exists.
    var refused: types.Document = .none;
    try testing.expectEqual(Result.invalid_argument, table.author_document_create(f.workspace, try f.revision(), .from("../outside.fdt"), &refused));
    try testing.expectEqual(Result.invalid_argument, table.author_document_create(f.workspace, try f.revision(), .from("notes.txt"), &refused));
    try testing.expectEqual(Result.already_exists, table.author_document_create(f.workspace, try f.revision(), .from("items.fdt"), &refused));

    // The bytes come back through a caller's buffer, with the needed length first.
    const document = try f.document("mod.fdt");
    var needed: u64 = 0;
    try testing.expectEqual(Result.limit, table.author_document_copy_source(document, null, 0, &needed));
    try testing.expectEqual(@as(u64, Fixture.manifest_text.len), needed);

    var buffer: [512]u8 = undefined;
    try testing.expectEqual(Result.ok, table.author_document_copy_source(document, &buffer, buffer.len, &needed));
    try testing.expectEqualStrings(Fixture.manifest_text, buffer[0..@intCast(needed)]);

    // A buffer that is too small is a limit, not a truncation.
    var small: [4]u8 = undefined;
    try testing.expectEqual(Result.limit, table.author_document_copy_source(document, &small, small.len, &needed));
}

test "handles from one workspace mean nothing after it is closed" {
    const f = try Fixture.init(.{});
    defer f.deinit();

    const document = try f.document("items.fdt");
    const torch = try f.record("items.fdt", "demo:torch");
    f.service.close(f.workspace.unwrap(author.ServiceHandle));

    var info: author_types.WorkspaceInfo = .{};
    var document_info: author_types.DocumentInfo = .{};
    var node: author_types.NodeInfo = .{};
    try testing.expectEqual(Result.invalid_handle, table.author_workspace_info(f.workspace, &info));
    try testing.expectEqual(Result.invalid_handle, table.author_document_info(document, &document_info));
    try testing.expectEqual(Result.invalid_handle, table.author_node_info(torch, &node));

    // And the enumeration is empty rather than answering for a workspace that is gone.
    var cursor: Cursor = .begin;
    var handle: types.Workspace = .none;
    try testing.expectEqual(Result.end, table.author_workspace_next(&cursor, &handle));
}
