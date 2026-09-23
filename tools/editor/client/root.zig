//! The standalone editor's unprivileged client: the complete authoring workflow.
//!
//! It sees only `foundry.h` through `foundry_api` and `std` utilities.  Every workspace,
//! document, record, schema, dependency, preview record, diagnostic, save result, build and
//! widget below crosses `FoundryApi_v4`; paths, service handles and implementation modules
//! never do.  If a form here needs something the table does not publish, the answer is a
//! recorded limit, never a private call (I4, `editor.md` §3).
//!
//! **Three rules shape every line of this file.**
//!
//! 1. *Read, describe, then act.*  A command is recorded while the frame is being described
//!    and carried out once `ui_end` has returned, because a command ends every walk and
//!    invalidates every borrowed string and node handle the description is still holding
//!    (`editor.md` §5).  One accepted UI action is one command, never one per character.
//! 2. *A node handle is a position in a parse, and dies at the next accepted command.*  So
//!    nothing here stores one across a frame.  What is stored across frames is a document
//!    index, a record's content id and a field path — identities a re-parse preserves.
//! 3. *Typed text stays in the form until it can form a valid command.*  Each scalar field
//!    owns a buffer seeded from the canonical spelling at the current revision; Apply sends
//!    it, and a refusal leaves both the buffer and the file exactly as they were.
//!
//! Its regions are `editor.md` §10's, mapped to Unreal Engine 5's editor for layout and
//! naming only: a main toolbar, an outliner, a details panel, a message log and a status
//! bar.  Every word it draws is `foundry:editor` content.

const std = @import("std");
const c = @import("foundry_api").c;

pub const Api = c.FoundryApi_v4;

const Result = c.FoundryResult;
const Cursor = c.FoundryCursor;
pub const Rect = c.FoundryUiRect;
const Str = c.FoundryStr;
const UiId = c.FoundryUiId;
const Bool = c.FoundryBool;
const Workspace = c.FoundryWorkspace;
const Document = c.FoundryDocument;
const Node = c.FoundrySourceNode;
const SchemaNode = c.FoundrySchemaNode;
const Build = c.FoundryBuild;
const Value = c.FoundryAuthorValue;

/// Every bound is stated, because every one of them is a number a client can hit.  The
/// node budget is the one that matters: the host issues source-node handles from a ring, so
/// a frame that asked for more than it holds would invalidate the handle its own pending
/// command is standing on.  These add to well under that ring.
const max_documents: u32 = 128;
const max_records: u32 = 64;
const max_field_rows: u32 = 96;
const max_schema_rows: u32 = 64;
const max_dependency_records: u32 = 64;
const max_preview_records: u32 = 64;
const max_diagnostics: u32 = 32;
const max_save_entries: u32 = 16;
const max_logs: u32 = 24;
const max_depth: u8 = 3;
const max_field_buffers: u32 = 24;
const max_row_targets: u32 = 24;
const max_form_targets: u32 = 6;
const max_dependency_targets: u32 = 8;
const field_capacity: u32 = 192;
const name_capacity: u32 = 128;

/// The one file name this client writes down, and the one engine schema it names.  A
/// manifest has to live somewhere and be of some type; naming those is not recognising
/// game content, and `fpack` reads the same two facts (`editor.md` §5).
const manifest_document = "mod.fdt";
const manifest_schema = "foundry:mod";

pub const Observation = struct {
    workspaces: u32 = 0,
    documents: u32 = 0,
    source_records: u32 = 0,
    dependencies: u32 = 0,
    dependency_records: u32 = 0,
    preview_records: u32 = 0,
    schemas: u32 = 0,
    assets: u32 = 0,
    diagnostics: u32 = 0,
    logs: u32 = 0,
    fields: u32 = 0,
    last_result: Result = c.FOUNDRY_OK,
};

/// One field of `foundry:editor.screen`.  Adding a word to the editor means adding it here
/// and in the package, never a literal below.
const TextKey = enum {
    title,
    workspace,
    documents,
    records,
    source_tab,
    dependencies,
    preview,
    schemas,
    assets,
    diagnostics,
    output_log,
    details,
    no_workspace,
    no_selection,
    no_records,
    no_diagnostics,
    status_ready,
    status_read_only,
    dirty,
    clean,
    unavailable,
    new_package,
    new_record,
    new_document,
    create,
    cancel,
    close,
    save,
    save_all,
    validate,
    build,
    reload,
    export_package,
    undo,
    redo,
    refresh,
    discard,
    apply,
    add,
    remove,
    reset,
    move_up,
    move_down,
    delete,
    duplicate,
    override,
    filter,
    package_id,
    package_name,
    package_version,
    package_license,
    document_path,
    schema_name,
    record_id,
    revision,
    build_revision,
    loaded,
    history_truncated,
    externally_changed,
    required,
    optional,
    defaulted,
    element,
    not_set,
    confirm_close,
    confirm_refresh,
    confirm_discard,
    override_warning,
    read_only,
};

const text_count = @typeInfo(TextKey).@"enum".fields.len;
const text_capacity = 96;

const Text = struct {
    bytes: [text_count][text_capacity]u8 = @splat(@splat(0)),
    lengths: [text_count]u8 = @splat(0),

    fn get(self: *const Text, key: TextKey) []const u8 {
        const index = @intFromEnum(key);
        return self.bytes[index][0..self.lengths[index]];
    }
};

const Tab = enum(u32) { source, dependencies, preview, schemas, assets };

/// What the host's keyboard produced, translated by the host because the public table
/// publishes no key state.  See the Step 7 Resolution: this is input the application owns,
/// not a Foundry capability the client reached around the table for — every action it
/// starts is still an ordinary v4 call below.
pub const Shortcut = enum { none, save, save_all, undo, redo, validate, build, close };

/// Where a deterministic script aims.  Recorded while the frame is described and read on a
/// later frame, exactly as the room's mod screen records its own.
pub const Targets = struct {
    /// Every control of one row of the details panel, in the order the panel described
    /// them.  A script that means "the third field" says so, instead of counting pixels.
    pub const Row = struct {
        control: ?Rect = null,
        apply: ?Rect = null,
        reset: ?Rect = null,
        add: ?Rect = null,
        element: ?Rect = null,
        remove: ?Rect = null,
        up: ?Rect = null,
        down: ?Rect = null,
    };

    rows: [max_row_targets]Row = @splat(.{}),
    row_count: u32 = 0,
    /// The current form's entry boxes, in the order it asked for them.
    form_fields: [max_form_targets]?Rect = @splat(null),
    new_package: ?Rect = null,
    new_record: ?Rect = null,
    new_document: ?Rect = null,
    save: ?Rect = null,
    save_all: ?Rect = null,
    validate: ?Rect = null,
    build: ?Rect = null,
    reload: ?Rect = null,
    export_package: ?Rect = null,
    undo: ?Rect = null,
    redo: ?Rect = null,
    form_create: ?Rect = null,
    form_cancel: ?Rect = null,
    /// The first schema row the New Record form drew.  The set is sorted, so this is a
    /// stable place for a script to aim even as schemas are granted.
    first_schema: ?Rect = null,
    filter: ?Rect = null,
    tabs: [5]?Rect = @splat(null),
    /// The granted packages, by their place in the grant.  Only the selected one's
    /// records are listed, so choosing the package is a step of its own.
    dependency_packages: [max_dependency_targets]?Rect = @splat(null),
    first_document: ?Rect = null,
    first_record: ?Rect = null,
    record_delete: ?Rect = null,
    record_duplicate: ?Rect = null,
    dependency_override: ?Rect = null,
    first_dependency_record: ?Rect = null,
    confirm_save: ?Rect = null,
    confirm_discard: ?Rect = null,
    confirm_cancel: ?Rect = null,
    document_refresh: ?Rect = null,
    document_discard: ?Rect = null,
};

/// What one accepted UI action asked for, carried out after the frame.
///
/// The node handles in here were issued during this same description and no command has
/// run since, so they are still live when `act` reaches them.  Every text slice points into
/// this client's own buffers, which outlive the frame.
const Command = union(enum) {
    none,
    create_package,
    create_record,
    create_document,
    duplicate: Node,
    delete: Node,
    override: Node,
    set: struct { node: Node, value: Value },
    unset: Node,
    list_insert: struct { node: Node, index: u32, value: Value },
    list_remove: struct { node: Node, index: u32 },
    list_move: struct { node: Node, from: u32, to: u32 },
    undo,
    redo,
    save_document: Document,
    save_all,
    validate,
    build,
    reload,
    export_build,
    refresh: Document,
    discard: Document,
};

/// An in-window confirmation, which is what §6 asks for instead of a popup layer.
const Confirm = union(enum) {
    none,
    close,
    refresh: Document,
    discard: Document,
};

/// One text-entry buffer, keyed by the field path it edits and reseeded whenever the
/// workspace revision moves.  Typing survives within a revision; a command that changes the
/// file re-reads the canonical spelling, which is what a Save would write.
const FieldSlot = struct {
    key: u64 = 0,
    revision: u64 = 0,
    used: bool = false,
    len: u64 = 0,
    bytes: [field_capacity]u8 = @splat(0),

    fn text(self: *const FieldSlot) []const u8 {
        return self.bytes[0..@intCast(self.len)];
    }
};

fn Entry(comptime capacity: u32) type {
    return struct {
        const Self = @This();
        len: u64 = 0,
        bytes: [capacity]u8 = @splat(0),

        fn text(self: *const Self) []const u8 {
            return self.bytes[0..@intCast(self.len)];
        }

        fn set(self: *Self, value: []const u8) void {
            const n = @min(value.len, self.bytes.len);
            @memcpy(self.bytes[0..n], value[0..n]);
            self.len = n;
        }
    };
}

/// Which form the outliner is showing above its lists.  One at a time, in the window.
const Form = enum { none, package, record, document };

pub const Client = struct {
    api: *const Api,
    generation: u64 = 0,
    text: Text = .{},
    theme: ?c.FoundryTheme = null,

    tab: Tab = .source,
    form: Form = .none,
    confirm: Confirm = .none,

    /// Selection is stored as identity, never as a handle: a document's index, a record's
    /// content id, a dependency's index.  A command re-parses, and every handle dies.
    selected_document: u32 = 0,
    selected_record: u64 = 0,
    has_record: bool = false,
    selected_dependency: u32 = 0,
    selected_dependency_record: u64 = 0,
    has_dependency_record: bool = false,

    filter: Entry(64) = .{},
    new_record_id: Entry(name_capacity) = .{},
    new_record_schema: Entry(name_capacity) = .{},
    new_document_path: Entry(name_capacity) = .{},
    package_id: Entry(name_capacity) = .{},
    package_name: Entry(name_capacity) = .{},
    package_version: Entry(16) = .{},
    package_license: Entry(48) = .{},
    duplicate_id: Entry(name_capacity) = .{},

    fields: [max_field_buffers]FieldSlot = @splat(.{}),
    field_next: u32 = 0,
    form_field_next: u32 = 0,

    pending: Command = .none,
    shortcut: Shortcut = .none,

    revision: u64 = 0,
    /// How many rows the details panel described last frame, which is the only honest
    /// estimate of how tall it will be this one: a cursor layout never sees the whole.
    last_rows: u32 = 0,
    build: Build = .{ .bits = 0 },
    has_build: bool = false,
    /// How many export destinations the host granted this workspace.  None is the
    /// ordinary case for a host that only wants a preview, and Export is then disabled.
    destinations: u32 = 0,
    previewed: Build = .{ .bits = 0 },
    has_previewed: bool = false,

    /// The last operation's outcome, in words the status bar prints.  A number, never a
    /// borrowed string: everything borrowed expires before the next frame reads it.
    status: [96]u8 = @splat(0),
    status_len: usize = 0,
    quit_requested: bool = false,

    observation: Observation = .{},
    targets: Targets = .{},

    pub fn init(api: *const Api) error{WrongApi}!Client {
        if (api.version != c.FOUNDRY_API_VERSION_4 or api.size < @sizeOf(Api)) return error.WrongApi;
        return .{ .api = api };
    }

    /// Whether anything in the workspace is unsaved, for a host reporting what a bounded
    /// run left behind.
    pub fn isDirty(self: *Client) bool {
        const info = self.workspaceInfo() orelse return false;
        return info.dirty != c.FOUNDRY_FALSE;
    }

    /// The host asks; the client decides whether anything would be lost.  Close with
    /// unsaved work raises the confirmation instead of quitting, and Cancel returns to the
    /// editor with every draft intact (`editor.md` §6).
    pub fn requestClose(self: *Client) void {
        if (self.workspaceInfo()) |info| {
            if (info.dirty != c.FOUNDRY_FALSE) {
                self.confirm = .close;
                return;
            }
        }
        self.quit_requested = true;
    }

    /// Builds and activates the first granted workspace using only public calls.  The host
    /// chooses every root and capability before this client exists.
    pub fn requestPreview(self: *Client) Result {
        const workspace = self.firstWorkspace() catch return self.note(c.FOUNDRY_ERR_UNAVAILABLE);

        var revision: u64 = 0;
        var result = self.api.author_workspace_revision.?(workspace, &revision);
        if (result != c.FOUNDRY_OK) return self.note(result);

        var build: Build = .{ .bits = 0 };
        result = self.api.author_build.?(workspace, revision, &build);
        if (result != c.FOUNDRY_OK) return self.note(result);
        self.build = build;
        self.has_build = true;

        result = self.api.author_preview_activate.?(build);
        if (result == c.FOUNDRY_OK) {
            self.previewed = build;
            self.has_previewed = true;
        }
        return self.note(result);
    }

    /// A bounded, non-rendering traversal used by the null smoke run.  It asks every
    /// browser its real public question once, so the proof does not depend on synthetic
    /// pointer input reaching five tabs in three frames.
    pub fn inspect(self: *Client) Observation {
        var seen: Observation = .{};
        var workspaces: Cursor = beginCursor();
        var workspace: Workspace = .{ .bits = 0 };
        while (seen.workspaces < max_documents and self.api.author_workspace_next.?(&workspaces, &workspace) == c.FOUNDRY_OK) {
            seen.workspaces += 1;

            var documents: Cursor = beginCursor();
            var document: Document = .{ .bits = 0 };
            while (seen.documents < max_documents and self.api.author_document_next.?(workspace, &documents, &document) == c.FOUNDRY_OK) {
                seen.documents += 1;
                var records: Cursor = beginCursor();
                var source: Node = .{ .bits = 0 };
                while (seen.source_records < max_records and self.api.author_record_next.?(document, &records, &source) == c.FOUNDRY_OK) {
                    seen.source_records += 1;
                    var info: c.FoundryAuthorNodeInfo = std.mem.zeroes(c.FoundryAuthorNodeInfo);
                    _ = self.api.author_node_info.?(source, &info);
                    seen.fields += info.child_count;
                }
            }

            var dependencies: Cursor = beginCursor();
            var package: c.FoundryAuthorPackageInfo = std.mem.zeroes(c.FoundryAuthorPackageInfo);
            while (seen.dependencies < max_documents and self.api.author_dependency_next.?(workspace, &dependencies, &package) == c.FOUNDRY_OK) {
                seen.dependencies += 1;
                var records: Cursor = beginCursor();
                var dependency: Node = .{ .bits = 0 };
                while (seen.dependency_records < max_dependency_records and
                    self.api.author_dependency_record_next.?(workspace, package.index, &records, &dependency) == c.FOUNDRY_OK)
                {
                    seen.dependency_records += 1;
                }
            }

            var preview: Cursor = beginCursor();
            var preview_record: Node = .{ .bits = 0 };
            while (seen.preview_records < max_preview_records and
                self.api.author_preview_record_next.?(workspace, &preview, &preview_record) == c.FOUNDRY_OK)
            {
                seen.preview_records += 1;
            }

            var schemas: Cursor = beginCursor();
            var schema: SchemaNode = .{ .bits = 0 };
            while (seen.schemas < max_schema_rows and self.api.author_schema_next.?(workspace, &schemas, &schema) == c.FOUNDRY_OK) {
                seen.schemas += 1;
                var info: c.FoundryAuthorSchemaNodeInfo = std.mem.zeroes(c.FoundryAuthorSchemaNodeInfo);
                _ = self.api.author_schema_node_info.?(schema, &info);
            }

            var diagnostics: Cursor = beginCursor();
            var diagnostic: c.FoundryAuthorDiagnostic = std.mem.zeroes(c.FoundryAuthorDiagnostic);
            while (seen.diagnostics < max_diagnostics and self.api.author_diagnostic_next.?(workspace, &diagnostics, &diagnostic) == c.FOUNDRY_OK) {
                seen.diagnostics += 1;
            }
        }

        var assets: Cursor = beginCursor();
        var loaded_asset: c.FoundryAsset = .{ .bits = 0 };
        while (seen.assets < max_documents and self.api.asset_next.?(&assets, &loaded_asset) == c.FOUNDRY_OK) seen.assets += 1;

        var logs: Cursor = beginCursor();
        var record: c.FoundryLogRecord = std.mem.zeroes(c.FoundryLogRecord);
        while (seen.logs < max_logs and self.api.log_next.?(&logs, &record) == c.FOUNDRY_OK) seen.logs += 1;
        self.observation = seen;
        return seen;
    }

    /// One editor frame: read the content strings, describe every region, then act on the
    /// single command the description recorded.
    pub fn frame(self: *Client, viewport: Rect, shortcut: Shortcut) void {
        self.observation = .{};
        self.targets = .{};
        self.form_field_next = 0;
        self.pending = .none;
        self.shortcut = shortcut;
        self.refreshContent();
        self.revision = if (self.workspaceInfo()) |info| info.revision else 0;
        self.destinations = self.exportCount();

        const pushed = if (self.theme) |theme|
            self.api.ui_theme_push.?(theme) == c.FOUNDRY_OK
        else
            false;
        if (self.theme != null and !pushed) self.theme = null;
        defer if (pushed) {
            _ = self.api.ui_theme_pop.?();
        };

        if (self.api.ui_begin.?(&viewport) != c.FOUNDRY_OK) return;
        self.describe(viewport) catch {
            _ = self.note(c.FOUNDRY_ERR_INTERNAL);
        };
        const ended = self.api.ui_end.?();
        if (ended != c.FOUNDRY_OK) _ = self.note(ended);

        self.last_rows = self.targets.row_count;
        self.applyShortcut();
        self.act();
    }

    // -- description ------------------------------------------------------------------

    fn describe(self: *Client, viewport: Rect) UiError!void {
        const toolbar_h: f32 = 42;
        const confirm_h: f32 = if (self.confirm == .none) 0 else 32;
        const status_h: f32 = 24;
        const output_h: f32 = @min(176, @max(96, viewport.h * 0.25));
        const left_w: f32 = @min(340, @max(240, viewport.w * 0.26));
        const top = toolbar_h + confirm_h;
        const body_h = @max(0, viewport.h - top - output_h - status_h);

        try self.panel(1, .{ .x = 0, .y = 0, .w = viewport.w, .h = toolbar_h });
        try self.toolbar();
        try self.endPanel();

        if (confirm_h != 0) {
            try self.panel(2, .{ .x = 0, .y = toolbar_h, .w = viewport.w, .h = confirm_h });
            try self.confirmation();
            try self.endPanel();
        }

        try self.panel(10, .{ .x = 0, .y = top, .w = left_w, .h = body_h });
        try self.outliner(body_h);
        try self.endPanel();

        try self.panel(20, .{ .x = left_w, .y = top, .w = @max(0, viewport.w - left_w), .h = body_h });
        try self.tabs();
        switch (self.tab) {
            .source => try self.detailsPane(),
            .dependencies => try self.dependencyPane(),
            .preview => try self.previewPane(),
            .schemas => try self.schemaPane(),
            .assets => try self.assetPane(),
        }
        try self.endPanel();

        try self.panel(30, .{ .x = 0, .y = top + body_h, .w = viewport.w, .h = output_h });
        try self.outputPane();
        try self.endPanel();

        try self.panel(40, .{ .x = 0, .y = viewport.h - status_h, .w = viewport.w, .h = status_h });
        try self.statusPane();
        try self.endPanel();
    }

    /// UE5's main toolbar: the commands, under the names UE5 uses, disabled exactly when
    /// the workspace says they would be refused.
    fn toolbar(self: *Client) UiError!void {
        const info = self.workspaceInfo();
        try self.row(3, 30);
        try self.label(self.text.get(.title));
        try self.spacer(16);

        const busy = self.confirm != .none;
        const can_edit = info != null and info.?.can_edit != c.FOUNDRY_FALSE and !busy;
        const can_save = info != null and info.?.can_save != c.FOUNDRY_FALSE and !busy;
        const can_build = info != null and info.?.can_build != c.FOUNDRY_FALSE and !busy;
        const dirty = info != null and info.?.dirty != c.FOUNDRY_FALSE;
        const changed = info != null and info.?.externally_changed != c.FOUNDRY_FALSE;

        self.targets.new_package = try self.remaining();
        if (try self.command(11, .new_package, can_edit)) self.form = if (self.form == .package) .none else .package;
        self.targets.new_record = try self.remaining();
        if (try self.command(12, .new_record, can_edit)) self.form = if (self.form == .record) .none else .record;
        self.targets.new_document = try self.remaining();
        if (try self.command(13, .new_document, can_edit)) self.form = if (self.form == .document) .none else .document;

        try self.spacer(12);
        self.targets.save = try self.remaining();
        if (try self.command(14, .save, can_save and dirty)) {
            if (self.currentDocument()) |document| self.pending = .{ .save_document = document };
        }
        self.targets.save_all = try self.remaining();
        if (try self.command(15, .save_all, can_save and dirty)) self.pending = .save_all;

        try self.spacer(12);
        self.targets.validate = try self.remaining();
        if (try self.command(16, .validate, can_edit or can_build)) self.pending = .validate;
        // Build takes the *saved* bytes, so it stays disabled while anything is dirty or
        // has changed under us — the same rule the service enforces (`editor.md` §7).
        self.targets.build = try self.remaining();
        if (try self.command(17, .build, can_build and !dirty and !changed)) self.pending = .build;
        self.targets.reload = try self.remaining();
        const can_reload = self.has_build and !busy and
            info != null and info.?.can_preview != c.FOUNDRY_FALSE;
        if (try self.command(18, .reload, can_reload)) self.pending = .reload;
        // A build nobody can take away is a build nobody can install.  Export writes it
        // to a destination the *host* granted — the client never names a path.
        self.targets.export_package = try self.remaining();
        if (try self.command(24, .export_package, self.has_build and self.destinations != 0 and !busy)) {
            self.pending = .export_build;
        }

        try self.spacer(12);
        self.targets.undo = try self.remaining();
        if (try self.command(19, .undo, can_edit and info.?.can_undo != c.FOUNDRY_FALSE)) self.pending = .undo;
        self.targets.redo = try self.remaining();
        if (try self.command(20, .redo, can_edit and info.?.can_redo != c.FOUNDRY_FALSE)) self.pending = .redo;
        try self.endRow();
    }

    fn confirmation(self: *Client) UiError!void {
        try self.row(4, 26);
        try self.label(switch (self.confirm) {
            .none => "",
            .close => self.text.get(.confirm_close),
            .refresh => self.text.get(.confirm_refresh),
            .discard => self.text.get(.confirm_discard),
        });
        try self.spacer(16);

        // Save is offered only where it is the answer: refreshing or discarding one
        // document is about that document, and closing is about the whole workspace.
        if (self.confirm == .close) {
            self.targets.confirm_save = try self.remaining();
            if (try self.button(21, .save)) {
                self.pending = .save_all;
                self.confirm = .none;
            }
        }
        self.targets.confirm_discard = try self.remaining();
        if (try self.button(22, .discard)) {
            switch (self.confirm) {
                .none => {},
                .close => self.quit_requested = true,
                .refresh => |document| self.pending = .{ .refresh = document },
                .discard => |document| self.pending = .{ .discard = document },
            }
            self.confirm = .none;
        }
        self.targets.confirm_cancel = try self.remaining();
        if (try self.button(23, .cancel)) self.confirm = .none;
        try self.endRow();
    }

    /// UE5's Outliner and Content Browser: the forms, then the documents, then the records
    /// of the selected one, filtered by one box.
    fn outliner(self: *Client, height: f32) UiError!void {
        const workspace = self.firstWorkspace() catch {
            try self.label(self.text.get(.no_workspace));
            return;
        };
        self.observation.workspaces = 1;

        switch (self.form) {
            .none => {},
            .package => try self.packageForm(),
            .record => try self.recordForm(workspace),
            .document => try self.documentForm(),
        }

        try self.row(31, 22);
        try self.label(self.text.get(.filter));
        self.targets.filter = try self.remaining();
        _ = try self.field(32, &self.filter.bytes, &self.filter.len);
        try self.endRow();
        try self.separator();

        try self.label(self.text.get(.documents));
        var documents: Cursor = beginCursor();
        var document: Document = .{ .bits = 0 };
        var at: u32 = 0;
        var selected_exists = false;
        while (at < max_documents) : (at += 1) {
            const next = self.api.author_document_next.?(workspace, &documents, &document);
            if (next == c.FOUNDRY_END) break;
            try ok(next);
            self.observation.documents += 1;

            var info: c.FoundryAuthorDocumentInfo = std.mem.zeroes(c.FoundryAuthorDocumentInfo);
            try ok(self.api.author_document_info.?(document, &info));
            const chosen = at == self.selected_document;
            if (chosen) selected_exists = true;

            try self.row(0x100 + at, 22);
            if (at == 0) self.targets.first_document = try self.remaining();
            var buffer: [name_capacity + 8]u8 = undefined;
            // UE5 marks an unsaved asset with an asterisk; an externally changed file gets
            // its own mark, because those are different problems with different answers.
            const mark: []const u8 = if (info.externally_changed != c.FOUNDRY_FALSE)
                "! "
            else if (info.dirty != c.FOUNDRY_FALSE)
                "* "
            else
                "  ";
            const shown = std.fmt.bufPrint(&buffer, "{s}{s}", .{ mark, span(info.path) }) catch span(info.path);
            var clicked: Bool = c.FOUNDRY_FALSE;
            try ok(self.api.ui_selectable.?(uid(0x200 + at), string(shown), boolOut(chosen), &clicked));
            if (clicked != c.FOUNDRY_FALSE) {
                self.selected_document = at;
                self.has_record = false;
            }
            if (chosen and info.externally_changed != c.FOUNDRY_FALSE) {
                self.targets.document_refresh = try self.remaining();
                if (try self.button(0x300 + at, .refresh)) self.confirm = .{ .refresh = document };
            }
            if (chosen and info.dirty != c.FOUNDRY_FALSE) {
                self.targets.document_discard = try self.remaining();
                if (try self.button(0x400 + at, .discard)) self.confirm = .{ .discard = document };
            }
            try self.endRow();
        }
        if (!selected_exists) self.selected_document = 0;
        try self.separator();

        try self.label(self.text.get(.records));
        const document_handle = self.currentDocument() orelse {
            try self.label(self.text.get(.no_selection));
            return;
        };
        var area = try self.remaining();
        area.h = @max(0, @min(area.h, height * 0.45));
        const metrics = try self.style();
        const step = metrics.line_height + metrics.spacing;
        try ok(self.api.ui_begin_scroll.?(uid(0x500), &area, @as(f32, @floatFromInt(self.recordCount(document_handle))) * step));
        defer _ = self.api.ui_end_scroll.?();

        var records: Cursor = beginCursor();
        var record: Node = .{ .bits = 0 };
        var index: u32 = 0;
        var shown: u32 = 0;
        while (index < max_records) : (index += 1) {
            const next = self.api.author_record_next.?(document_handle, &records, &record);
            if (next == c.FOUNDRY_END) break;
            try ok(next);
            self.observation.source_records += 1;
            var info: c.FoundryAuthorNodeInfo = std.mem.zeroes(c.FoundryAuthorNodeInfo);
            try ok(self.api.author_node_info.?(record, &info));
            const name = span(info.name);
            if (!self.passes(name)) continue;
            if (shown == 0) self.targets.first_record = try self.remaining();
            shown += 1;
            const chosen = self.has_record and self.selected_record == info.id.hash;
            var clicked: Bool = c.FOUNDRY_FALSE;
            try ok(self.api.ui_selectable.?(uid(0x600 + index), info.name, boolOut(chosen), &clicked));
            if (clicked != c.FOUNDRY_FALSE) {
                self.selected_record = info.id.hash;
                self.has_record = true;
            }
        }
        if (shown == 0) try self.label(self.text.get(.no_records));
    }

    /// New Package: an ordinary `foundry:mod` record, in an ordinary document, with the
    /// three fields the manifest requires and nothing invented.  It grants no native
    /// consent and states no ABI range — a content-only package claims neither
    /// (`editor.md` §5).
    fn packageForm(self: *Client) UiError!void {
        try self.label(self.text.get(.new_package));
        try self.entryRow(70, .package_id, &self.package_id.bytes, &self.package_id.len);
        try self.entryRow(71, .package_name, &self.package_name.bytes, &self.package_name.len);
        try self.entryRow(72, .package_version, &self.package_version.bytes, &self.package_version.len);
        try self.entryRow(73, .package_license, &self.package_license.bytes, &self.package_license.len);
        try self.formButtons(74, self.package_id.len != 0 and self.package_name.len != 0 and self.package_license.len != 0, .create_package);
        try self.separator();
    }

    fn recordForm(self: *Client, workspace: Workspace) UiError!void {
        try self.label(self.text.get(.new_record));
        try self.entryRow(80, .schema_name, &self.new_record_schema.bytes, &self.new_record_schema.len);
        try self.entryRow(81, .record_id, &self.new_record_id.bytes, &self.new_record_id.len);

        // The schema list is published for exactly this: a registry holds hashes, and a
        // form needs the words.  Choosing one fills the box the author could also type in.
        var cursor: Cursor = beginCursor();
        var schema: SchemaNode = .{ .bits = 0 };
        var index: u32 = 0;
        while (index < max_schema_rows) : (index += 1) {
            const next = self.api.author_schema_next.?(workspace, &cursor, &schema);
            if (next == c.FOUNDRY_END) break;
            try ok(next);
            var info: c.FoundryAuthorSchemaNodeInfo = std.mem.zeroes(c.FoundryAuthorSchemaNodeInfo);
            try ok(self.api.author_schema_node_info.?(schema, &info));
            const name = span(info.name);
            if (!self.passes(name)) continue;
            self.observation.schemas += 1;
            if (self.targets.first_schema == null) self.targets.first_schema = try self.remaining();
            var clicked: Bool = c.FOUNDRY_FALSE;
            try ok(self.api.ui_selectable.?(
                uid(0x700 + index),
                info.name,
                boolOut(std.mem.eql(u8, name, self.new_record_schema.text())),
                &clicked,
            ));
            if (clicked != c.FOUNDRY_FALSE) self.new_record_schema.set(name);
        }
        try self.formButtons(82, self.new_record_schema.len != 0 and self.new_record_id.len != 0, .create_record);
        try self.separator();
    }

    fn documentForm(self: *Client) UiError!void {
        try self.label(self.text.get(.new_document));
        try self.entryRow(90, .document_path, &self.new_document_path.bytes, &self.new_document_path.len);
        try self.formButtons(91, self.new_document_path.len != 0, .create_document);
        try self.separator();
    }

    fn formButtons(self: *Client, base: u64, ready: bool, what: Command) UiError!void {
        try self.row(base, 22);
        self.targets.form_create = try self.remaining();
        if (try self.command(base + 1, .create, ready)) self.pending = what;
        self.targets.form_cancel = try self.remaining();
        if (try self.button(base + 2, .cancel)) self.form = .none;
        try self.endRow();
    }

    fn entryRow(self: *Client, id: u64, key: TextKey, buffer: []u8, len: *u64) UiError!void {
        try self.row(id, 22);
        try self.label(self.text.get(key));
        const at = try self.remaining();
        if (self.form_field_next < max_form_targets) {
            self.targets.form_fields[self.form_field_next] = at;
            self.form_field_next += 1;
        }
        _ = try self.field(id + 0x40, buffer, len);
        try self.endRow();
    }

    fn tabs(self: *Client) UiError!void {
        const labels = [_]Str{
            string(self.text.get(.source_tab)),
            string(self.text.get(.dependencies)),
            string(self.text.get(.preview)),
            string(self.text.get(.schemas)),
            string(self.text.get(.assets)),
        };
        // The strip's geometry, measured the way the kernel measures it: a tab is as wide
        // as its own label. A script that assumed equal shares would click the wrong one
        // as soon as a translation changed a word.
        const start = try self.remaining();
        const metrics = try self.style();
        var x = start.x;
        for (&self.targets.tabs, labels) |*target, text| {
            const width = @max(0, measure(metrics, span(text)) + metrics.padding.x * 2);
            target.* = .{ .x = x, .y = start.y, .w = width, .h = metrics.line_height };
            x += width + @max(0, metrics.spacing);
        }
        var selected: u32 = @intFromEnum(self.tab);
        try ok(self.api.ui_tabs.?(uid(200), &labels, labels.len, &selected));
        self.tab = std.enums.fromInt(Tab, selected) orelse .source;
        try self.separator();
    }

    // -- the details panel ------------------------------------------------------------

    /// UE5's Details panel: the selected record, every field typed, with presence and
    /// authorship said separately because they are different answers (`editor.md` §5).
    fn detailsPane(self: *Client) UiError!void {
        const document = self.currentDocument() orelse {
            try self.label(self.text.get(.no_selection));
            return;
        };
        const found = self.findRecord(document) orelse {
            try self.label(self.text.get(.no_selection));
            return;
        };

        var info: c.FoundryAuthorNodeInfo = std.mem.zeroes(c.FoundryAuthorNodeInfo);
        try ok(self.api.author_node_info.?(found, &info));
        const writable = info.writable != c.FOUNDRY_FALSE;

        try self.row(210, 24);
        try self.label(self.text.get(.details));
        try self.label(span(info.name));
        if (!writable) try self.label(self.text.get(.read_only));
        if (writable) {
            self.targets.record_delete = try self.remaining();
            if (try self.button(211, .delete)) self.pending = .{ .delete = found };
            self.targets.record_duplicate = try self.remaining();
            if (try self.command(212, .duplicate, self.duplicate_id.len != 0)) self.pending = .{ .duplicate = found };
            _ = try self.field(213, &self.duplicate_id.bytes, &self.duplicate_id.len);
        }
        try self.endRow();
        try self.separator();

        var area = try self.remaining();
        const metrics = try self.style();
        const step = metrics.line_height + metrics.spacing;
        const rows = @max(info.child_count, self.last_rows) + 2;
        try ok(self.api.ui_begin_scroll.?(uid(214), &area, @as(f32, @floatFromInt(rows)) * step));
        defer _ = self.api.ui_end_scroll.?();

        const schema = self.schemaNodeFor(info.schema.hash);
        try self.children(found, schema, info.child_count, 0, self.selected_record, writable);
    }

    /// One node's children, paired with the same place in the schema declaration.
    ///
    /// The pairing is what lets a form lay out a block nobody has written yet, and what
    /// gives an empty list its element type.  Neither is recoverable from the source alone.
    fn children(
        self: *Client,
        parent: Node,
        schema: ?SchemaNode,
        count: u32,
        depth: u8,
        key: u64,
        writable: bool,
    ) UiError!void {
        if (depth >= max_depth) return;
        var index: u32 = 0;
        while (index < count and self.observation.fields < max_field_rows) : (index += 1) {
            var child: Node = .{ .bits = 0 };
            const result = self.api.author_node_child.?(parent, index, &child);
            if (result != c.FOUNDRY_OK) break;
            self.observation.fields += 1;
            const child_schema = self.schemaChild(schema, index);
            try self.fieldRow(child, child_schema, depth, hashOf(key, index), writable);
        }
    }

    fn fieldRow(self: *Client, node: Node, schema: ?SchemaNode, depth: u8, key: u64, writable: bool) UiError!void {
        var info: c.FoundryAuthorNodeInfo = std.mem.zeroes(c.FoundryAuthorNodeInfo);
        try ok(self.api.author_node_info.?(node, &info));
        const editable = writable and info.writable != c.FOUNDRY_FALSE;

        switch (info.field_type) {
            c.FOUNDRY_FIELD_NESTED => try self.containerRow(node, schema, info, depth, key, editable, false),
            c.FOUNDRY_FIELD_LIST => try self.containerRow(node, schema, info, depth, key, editable, true),
            else => try self.scalarRow(node, info, depth, key, editable),
        }
    }

    /// The next row of the details panel, so a script can name "the third field" instead
    /// of measuring one.  Rows are pushed in description order, which is schema order.
    fn pushRow(self: *Client) ?*Targets.Row {
        const index = self.targets.row_count;
        if (index >= max_row_targets) return null;
        self.targets.row_count += 1;
        return &self.targets.rows[index];
    }

    fn scalarRow(self: *Client, node: Node, info: c.FoundryAuthorNodeInfo, depth: u8, key: u64, editable: bool) UiError!void {
        var value: Value = std.mem.zeroes(Value);
        const read = self.api.author_node_scalar.?(node, &value);
        if (read != c.FOUNDRY_OK) return;
        const slot_targets = self.pushRow();

        try self.row(key | 0x1000_0000_0000_0000, 22);
        defer _ = self.api.ui_end_row.?();
        if (depth != 0) try self.spacer(@as(f32, @floatFromInt(depth)) * 14);
        try self.label(span(info.name));
        try self.label(self.presenceText(info));

        if (info.field_type == c.FOUNDRY_FIELD_BOOL) {
            var checked = value.boolean;
            var changed: Bool = c.FOUNDRY_FALSE;
            if (slot_targets) |t| t.control = try self.remaining();
            if (!editable) try ok(self.api.ui_begin_disabled.?());
            const result = self.api.ui_checkbox.?(uid(key ^ salt_control), string(""), &checked, &changed);
            if (!editable) try ok(self.api.ui_end_disabled.?());
            try ok(result);
            if (changed != c.FOUNDRY_FALSE and editable) {
                var out: Value = std.mem.zeroes(Value);
                out.field_type = c.FOUNDRY_FIELD_BOOL;
                out.boolean = checked;
                self.pending = .{ .set = .{ .node = node, .value = out } };
            }
        } else {
            const slot = self.slotFor(key, span(value.text));
            if (slot_targets) |t| t.control = try self.remaining();
            if (!editable) try ok(self.api.ui_begin_disabled.?());
            const typed = self.field(key ^ salt_control, &slot.bytes, &slot.len) catch |err| {
                if (!editable) try ok(self.api.ui_end_disabled.?());
                return err;
            };
            _ = typed;
            if (!editable) try ok(self.api.ui_end_disabled.?());

            if (slot_targets) |t| t.apply = try self.remaining();
            if (try self.command(key ^ salt_apply, .apply, editable)) {
                var out: Value = std.mem.zeroes(Value);
                out.field_type = info.field_type;
                out.text = string(slot.text());
                self.pending = .{ .set = .{ .node = node, .value = out } };
            }
        }

        // UE5's reset-to-default arrow, and the reason `authored` is a separate answer: a
        // defaulted field nobody wrote has nothing to reset.
        const resettable = editable and info.authored != c.FOUNDRY_FALSE and
            info.presence != c.FOUNDRY_AUTHOR_REQUIRED and info.presence != c.FOUNDRY_AUTHOR_ELEMENT;
        if (slot_targets) |t| t.reset = try self.remaining();
        if (try self.command(key ^ salt_reset, .reset, resettable)) self.pending = .{ .unset = node };
        if (info.authored == c.FOUNDRY_FALSE) try self.label(self.text.get(.not_set));
    }

    fn containerRow(
        self: *Client,
        node: Node,
        schema: ?SchemaNode,
        info: c.FoundryAuthorNodeInfo,
        depth: u8,
        key: u64,
        editable: bool,
        is_list: bool,
    ) UiError!void {
        const slot_targets = self.pushRow();
        try self.row(key | 0x2000_0000_0000_0000, 22);
        if (depth != 0) try self.spacer(@as(f32, @floatFromInt(depth)) * 14);
        if (slot_targets) |t| t.control = try self.remaining();
        var open: Bool = c.FOUNDRY_FALSE;
        try ok(self.api.ui_collapsing_header.?(uid(key ^ salt_control), info.name, &open));
        try self.label(self.presenceText(info));
        if (info.authored == c.FOUNDRY_FALSE) try self.label(self.text.get(.not_set));

        // "Add the optional block" and "start a list" are both said as a value: the
        // container's own type with empty text (`editor.md` §5).
        const startable = editable and info.authored == c.FOUNDRY_FALSE;
        if (slot_targets) |t| t.add = try self.remaining();
        if (try self.command(key ^ salt_add, .add, startable)) {
            var out: Value = std.mem.zeroes(Value);
            out.field_type = info.field_type;
            self.pending = .{ .set = .{ .node = node, .value = out } };
        }
        if (is_list and editable and info.authored != c.FOUNDRY_FALSE) {
            const slot = self.slotFor(key ^ salt_element, "");
            if (slot_targets) |t| t.element = try self.remaining();
            _ = try self.field(key ^ salt_element, &slot.bytes, &slot.len);
            if (slot_targets) |t| t.add = try self.remaining();
            if (try self.button(key ^ salt_add ^ salt_element, .add)) {
                var out: Value = std.mem.zeroes(Value);
                out.field_type = self.elementType(schema);
                out.text = string(slot.text());
                self.pending = .{ .list_insert = .{ .node = node, .index = info.child_count, .value = out } };
            }
        }
        const resettable = editable and info.authored != c.FOUNDRY_FALSE and
            info.presence != c.FOUNDRY_AUTHOR_REQUIRED and info.presence != c.FOUNDRY_AUTHOR_ELEMENT;
        if (slot_targets) |t| t.reset = try self.remaining();
        if (try self.command(key ^ salt_reset, .reset, resettable)) self.pending = .{ .unset = node };
        try self.endRow();

        if (open == c.FOUNDRY_FALSE) return;
        if (!is_list) {
            try self.children(node, schema, info.child_count, depth + 1, key, editable);
            return;
        }

        // A list's children are elements, and its schema child is the element *type*: one
        // declaration for every position.
        const element_schema = self.schemaChild(schema, 0);
        var index: u32 = 0;
        while (index < info.child_count and self.observation.fields < max_field_rows) : (index += 1) {
            var child: Node = .{ .bits = 0 };
            if (self.api.author_node_child.?(node, index, &child) != c.FOUNDRY_OK) break;
            self.observation.fields += 1;
            const child_key = hashOf(key, index);
            // The element's own row is pushed by `fieldRow`; its list controls belong to
            // that same row, so the script has one place to look for them.
            const element_row = self.targets.row_count;
            try self.fieldRow(child, element_schema, depth + 1, child_key, editable);
            const controls: ?*Targets.Row =
                if (element_row < self.targets.row_count) &self.targets.rows[element_row] else null;
            try self.row(child_key | 0x3000_0000_0000_0000, 20);
            try self.spacer(@as(f32, @floatFromInt(depth + 1)) * 14);
            if (controls) |t| t.remove = try self.remaining();
            if (try self.command(child_key ^ salt_remove, .remove, editable)) {
                self.pending = .{ .list_remove = .{ .node = node, .index = index } };
            }
            if (controls) |t| t.up = try self.remaining();
            if (try self.command(child_key ^ salt_up, .move_up, editable and index != 0)) {
                self.pending = .{ .list_move = .{ .node = node, .from = index, .to = index - 1 } };
            }
            if (controls) |t| t.down = try self.remaining();
            if (try self.command(child_key ^ salt_down, .move_down, editable and index + 1 < info.child_count)) {
                self.pending = .{ .list_move = .{ .node = node, .from = index, .to = index + 1 } };
            }
            try self.endRow();
        }
    }

    // -- the other tabs ---------------------------------------------------------------

    fn dependencyPane(self: *Client) UiError!void {
        const workspace = try self.firstWorkspace();
        try self.label(self.text.get(.override_warning));
        try self.separator();

        // The package whose records this frame lists, read once before anything is
        // described.  Choosing a different one takes effect on the next frame: read,
        // describe, then act (`editor.md` §5).  Answering the click inside the loop made
        // the frame list two packages at once, and their rows then shared widget ids.
        const listing = self.selected_dependency;
        var packages: Cursor = beginCursor();
        var package: c.FoundryAuthorPackageInfo = std.mem.zeroes(c.FoundryAuthorPackageInfo);
        while (self.observation.dependencies < max_documents) {
            const result = self.api.author_dependency_next.?(workspace, &packages, &package);
            if (result == c.FOUNDRY_END) break;
            try ok(result);
            self.observation.dependencies += 1;
            if (package.index < max_dependency_targets) {
                self.targets.dependency_packages[package.index] = try self.remaining();
            }
            var clicked: Bool = c.FOUNDRY_FALSE;
            try ok(self.api.ui_selectable.?(
                uid(0x800 + package.index),
                package.name,
                boolOut(package.index == self.selected_dependency),
                &clicked,
            ));
            if (clicked != c.FOUNDRY_FALSE) self.selected_dependency = package.index;
            if (package.index != listing) continue;

            var records: Cursor = beginCursor();
            var record: Node = .{ .bits = 0 };
            var index: u32 = 0;
            var shown: u32 = 0;
            while (index < max_dependency_records) : (index += 1) {
                const next = self.api.author_dependency_record_next.?(workspace, package.index, &records, &record);
                if (next == c.FOUNDRY_END) break;
                try ok(next);
                self.observation.dependency_records += 1;
                var info: c.FoundryAuthorNodeInfo = std.mem.zeroes(c.FoundryAuthorNodeInfo);
                try ok(self.api.author_node_info.?(record, &info));
                if (!self.passes(span(info.name))) continue;
                const chosen = self.has_dependency_record and self.selected_dependency_record == info.id.hash;

                try self.row(0x900 + index, 22);
                // The first row that is *shown*, not the first that exists: a filtered
                // list's first entry is the one a reader sees at the top of it.
                if (shown == 0) self.targets.first_dependency_record = try self.remaining();
                shown += 1;
                var clicked_record: Bool = c.FOUNDRY_FALSE;
                try ok(self.api.ui_selectable.?(uid(0xA00 + index), info.name, boolOut(chosen), &clicked_record));
                if (clicked_record != c.FOUNDRY_FALSE) {
                    self.selected_dependency_record = info.id.hash;
                    self.has_dependency_record = true;
                }
                try self.endRow();

                // A selectable consumes the whole row by contract.  Put the action on a
                // row of its own: placing it after the selectable made a working but
                // clipped button beyond the panel, which synthetic input could reach and
                // a real author could not.
                if (chosen or clicked_record != c.FOUNDRY_FALSE) {
                    try self.row(0xB00 + index, 22);
                    self.targets.dependency_override = try self.remaining();
                    const into = self.currentDocument();
                    if (try self.command(0xC00 + index, .override, into != null)) {
                        self.pending = .{ .override = record };
                    }
                    try self.endRow();
                }
            }
        }
    }

    fn previewPane(self: *Client) UiError!void {
        const workspace = try self.firstWorkspace();
        var info: c.FoundryAuthorPreviewInfo = std.mem.zeroes(c.FoundryAuthorPreviewInfo);
        const state = self.api.author_preview_info.?(workspace, &info);
        if (state != c.FOUNDRY_OK or info.available == c.FOUNDRY_FALSE) {
            try self.label(self.text.get(.unavailable));
            return;
        }
        var records: Cursor = beginCursor();
        var record: Node = .{ .bits = 0 };
        while (self.observation.preview_records < max_preview_records) {
            const result = self.api.author_preview_record_next.?(workspace, &records, &record);
            if (result == c.FOUNDRY_END or result == c.FOUNDRY_ERR_NOT_FOUND) break;
            try ok(result);
            self.observation.preview_records += 1;
            var node: c.FoundryAuthorNodeInfo = std.mem.zeroes(c.FoundryAuthorNodeInfo);
            try ok(self.api.author_node_info.?(record, &node));
            try self.label(span(node.name));
        }
    }

    fn schemaPane(self: *Client) UiError!void {
        const workspace = try self.firstWorkspace();
        var cursor: Cursor = beginCursor();
        var schema: SchemaNode = .{ .bits = 0 };
        while (self.observation.schemas < max_schema_rows) {
            const result = self.api.author_schema_next.?(workspace, &cursor, &schema);
            if (result == c.FOUNDRY_END) break;
            try ok(result);
            self.observation.schemas += 1;
            try self.schemaNode(schema, 0);
        }
    }

    fn schemaNode(self: *Client, handle: SchemaNode, depth: u8) UiError!void {
        var info: c.FoundryAuthorSchemaNodeInfo = std.mem.zeroes(c.FoundryAuthorSchemaNodeInfo);
        try ok(self.api.author_schema_node_info.?(handle, &info));
        try self.indentedLabel(depth, span(info.name));
        if (depth >= 2) return;
        const count = @min(info.child_count, max_schema_rows);
        for (0..count) |index| {
            var child: SchemaNode = .{ .bits = 0 };
            if (self.api.author_schema_node_child.?(handle, @intCast(index), &child) != c.FOUNDRY_OK) break;
            try self.schemaNode(child, depth + 1);
        }
    }

    fn assetPane(self: *Client) UiError!void {
        var cursor: Cursor = beginCursor();
        var asset: c.FoundryAsset = .{ .bits = 0 };
        while (self.observation.assets < max_documents) {
            const result = self.api.asset_next.?(&cursor, &asset);
            if (result == c.FOUNDRY_END) break;
            if (result != c.FOUNDRY_OK) return self.label(self.text.get(.unavailable));
            self.observation.assets += 1;
            var content_id: c.FoundryContentId = .{ .hash = 0 };
            try ok(self.api.asset_content_id.?(asset, &content_id));
            var name: Str = string("");
            if (self.api.id_to_string.?(content_id, &name) == c.FOUNDRY_OK) try self.label(span(name));
        }
    }

    /// UE5's Message Log and Output Log: the diagnostic snapshot, what the last Save All
    /// actually did, and the engine's own ring.
    fn outputPane(self: *Client) UiError!void {
        try self.row(301, 24);
        try self.label(self.text.get(.diagnostics));
        try self.spacer(24);
        try self.label(self.text.get(.output_log));
        try self.endRow();
        try self.separator();

        if (self.firstWorkspace()) |workspace| {
            var cursor: Cursor = beginCursor();
            var diagnostic: c.FoundryAuthorDiagnostic = std.mem.zeroes(c.FoundryAuthorDiagnostic);
            while (self.observation.diagnostics < max_diagnostics) {
                const result = self.api.author_diagnostic_next.?(workspace, &cursor, &diagnostic);
                if (result != c.FOUNDRY_OK) break;
                const index = self.observation.diagnostics;
                self.observation.diagnostics += 1;
                var buffer: [192]u8 = undefined;
                const line = std.fmt.bufPrint(&buffer, "{s}:{d}:{d} {s}", .{
                    span(diagnostic.file),
                    diagnostic.line,
                    diagnostic.column,
                    span(diagnostic.message),
                }) catch span(diagnostic.message);
                var clicked: Bool = c.FOUNDRY_FALSE;
                try ok(self.api.ui_selectable.?(uid(0xC00 + index), string(line), c.FOUNDRY_FALSE, &clicked));
                // UE5's Message Log selects what an entry is about.  A diagnostic names a
                // file, so the entry selects that document.
                if (clicked != c.FOUNDRY_FALSE) self.selectDocumentNamed(workspace, span(diagnostic.file));
            }
            if (self.observation.diagnostics == 0) try self.label(self.text.get(.no_diagnostics));

            var entries: Cursor = beginCursor();
            var entry: c.FoundryAuthorSaveEntry = std.mem.zeroes(c.FoundryAuthorSaveEntry);
            var count: u32 = 0;
            while (count < max_save_entries) : (count += 1) {
                if (self.api.author_save_entry_next.?(workspace, &entries, &entry) != c.FOUNDRY_OK) break;
                var buffer: [160]u8 = undefined;
                const line = std.fmt.bufPrint(&buffer, "{s} {s}", .{
                    span(entry.path),
                    self.text.get(switch (entry.outcome) {
                        c.FOUNDRY_AUTHOR_SAVE_PUBLISHED => .save,
                        c.FOUNDRY_AUTHOR_SAVE_UNCHANGED => .clean,
                        else => .unavailable,
                    }),
                }) catch span(entry.path);
                try self.label(line);
            }
        } else |_| {}

        var logs: Cursor = beginCursor();
        var record: c.FoundryLogRecord = std.mem.zeroes(c.FoundryLogRecord);
        while (self.observation.logs < max_logs) {
            const result = self.api.log_next.?(&logs, &record);
            if (result != c.FOUNDRY_OK) break;
            self.observation.logs += 1;
            try self.label(span(record.text));
        }
    }

    fn statusPane(self: *Client) UiError!void {
        try self.row(401, 20);
        const info = self.workspaceInfo();
        var buffer: [128]u8 = undefined;
        if (info) |value| {
            const line = std.fmt.bufPrint(&buffer, "{s} {d}", .{ self.text.get(.revision), value.revision }) catch "";
            try self.label(line);
            try self.spacer(14);
            try self.label(self.text.get(if (value.dirty != c.FOUNDRY_FALSE) .dirty else .clean));
            if (value.externally_changed != c.FOUNDRY_FALSE) {
                try self.spacer(14);
                try self.label(self.text.get(.externally_changed));
            }
            if (value.history_truncated != c.FOUNDRY_FALSE) {
                try self.spacer(14);
                try self.label(self.text.get(.history_truncated));
            }
            if (value.can_edit == c.FOUNDRY_FALSE) {
                try self.spacer(14);
                try self.label(self.text.get(.status_read_only));
            }
        } else {
            try self.label(self.text.get(.no_workspace));
        }

        if (self.has_build) {
            var build: c.FoundryAuthorBuildInfo = std.mem.zeroes(c.FoundryAuthorBuildInfo);
            if (self.api.author_build_info.?(self.build, &build) == c.FOUNDRY_OK) {
                try self.spacer(14);
                const line = std.fmt.bufPrint(&buffer, "{s} {d}", .{ self.text.get(.build_revision), build.revision }) catch "";
                try self.label(line);
            }
        }
        if (self.firstWorkspace()) |workspace| {
            var preview: c.FoundryAuthorPreviewInfo = std.mem.zeroes(c.FoundryAuthorPreviewInfo);
            if (self.api.author_preview_info.?(workspace, &preview) == c.FOUNDRY_OK and
                preview.outcome == c.FOUNDRY_AUTHOR_PREVIEW_ACTIVE)
            {
                try self.spacer(14);
                const line = std.fmt.bufPrint(&buffer, "{s} {d}", .{ self.text.get(.loaded), preview.build_revision }) catch "";
                try self.label(line);
            }
        } else |_| {}

        try self.spacer(14);
        try self.label(if (self.status_len != 0) self.status[0..self.status_len] else self.text.get(.status_ready));
        try self.endRow();
    }

    // -- acting -------------------------------------------------------------------------

    /// A shortcut is the same action a button starts, so it goes through the same field.
    /// It never overrides a click made in the same frame.
    fn applyShortcut(self: *Client) void {
        if (self.pending != .none or self.shortcut == .none) return;
        if (self.confirm != .none and self.shortcut != .close) return;
        const info = self.workspaceInfo() orelse return;
        switch (self.shortcut) {
            .none => {},
            .save => if (info.can_save != c.FOUNDRY_FALSE) {
                if (self.currentDocument()) |document| self.pending = .{ .save_document = document };
            },
            .save_all => if (info.can_save != c.FOUNDRY_FALSE) {
                self.pending = .save_all;
            },
            .undo => if (info.can_undo != c.FOUNDRY_FALSE) {
                self.pending = .undo;
            },
            .redo => if (info.can_redo != c.FOUNDRY_FALSE) {
                self.pending = .redo;
            },
            .validate => self.pending = .validate,
            .build => if (info.can_build != c.FOUNDRY_FALSE and info.dirty == c.FOUNDRY_FALSE) {
                self.pending = .build;
            },
            .close => self.requestClose(),
        }
    }

    fn act(self: *Client) void {
        const requested = self.pending;
        self.pending = .none;
        if (requested == .none) return;

        const workspace = self.firstWorkspace() catch return;
        const revision = self.revision;
        var edit: c.FoundryAuthorEdit = std.mem.zeroes(c.FoundryAuthorEdit);

        const result: Result = switch (requested) {
            .none => c.FOUNDRY_OK,
            .create_package => blk: {
                const code = self.createPackage(workspace, revision, &edit);
                if (code == c.FOUNDRY_OK) self.selectDocumentNamed(workspace, manifest_document);
                break :blk code;
            },
            .create_record => blk: {
                const document = self.currentDocument() orelse break :blk c.FOUNDRY_ERR_NOT_FOUND;
                break :blk self.api.author_record_create.?(
                    document,
                    revision,
                    string(self.new_record_schema.text()),
                    string(self.new_record_id.text()),
                    &edit,
                );
            },
            .create_document => blk: {
                var document: Document = .{ .bits = 0 };
                const code = self.api.author_document_create.?(
                    workspace,
                    revision,
                    string(self.new_document_path.text()),
                    &document,
                );
                // A file you just made is the one you are working in.
                if (code == c.FOUNDRY_OK) self.selectDocumentNamed(workspace, self.new_document_path.text());
                break :blk code;
            },
            .duplicate => |node| blk: {
                const document = self.currentDocument() orelse break :blk c.FOUNDRY_ERR_NOT_FOUND;
                break :blk self.api.author_record_duplicate.?(node, document, revision, string(self.duplicate_id.text()), &edit);
            },
            .delete => |node| self.api.author_record_delete.?(node, revision, &edit),
            .override => |node| blk: {
                const document = self.currentDocument() orelse break :blk c.FOUNDRY_ERR_NOT_FOUND;
                break :blk self.api.author_record_override.?(node, document, revision, &edit);
            },
            .set => |set| self.api.author_value_set.?(set.node, revision, &set.value, &edit),
            .unset => |node| self.api.author_value_unset.?(node, revision, &edit),
            .list_insert => |insert| self.api.author_list_insert.?(insert.node, revision, insert.index, &insert.value, &edit),
            .list_remove => |remove| self.api.author_list_remove.?(remove.node, revision, remove.index, &edit),
            .list_move => |move| self.api.author_list_move.?(move.node, revision, move.from, move.to, &edit),
            .undo => self.api.author_undo.?(workspace, revision, &edit),
            .redo => self.api.author_redo.?(workspace, revision, &edit),
            .save_document => |document| blk: {
                var saved: c.FoundryAuthorSaveResult = std.mem.zeroes(c.FoundryAuthorSaveResult);
                const code = self.api.author_save_document.?(document, revision, &saved);
                if (code == c.FOUNDRY_OK) self.report("save", @intCast(saved.outcome));
                break :blk code;
            },
            .save_all => blk: {
                var all: c.FoundryAuthorSaveAll = std.mem.zeroes(c.FoundryAuthorSaveAll);
                const code = self.api.author_save_all.?(workspace, revision, &all);
                if (code == c.FOUNDRY_OK) self.report("saved", all.published_count);
                break :blk code;
            },
            .validate => self.api.author_validate.?(workspace, revision),
            .build => self.runBuild(workspace, revision),
            .reload => self.runReload(),
            .export_build => blk: {
                if (!self.has_build) break :blk c.FOUNDRY_ERR_NOT_FOUND;
                var written: u32 = 0;
                const code = self.api.author_build_export.?(self.build, 0, &written);
                if (code == c.FOUNDRY_OK) self.report("exported", written);
                break :blk code;
            },
            .refresh => |document| blk: {
                var moved: u64 = 0;
                break :blk self.api.author_document_refresh.?(document, revision, &moved);
            },
            .discard => |document| blk: {
                var moved: u64 = 0;
                break :blk self.api.author_document_discard.?(document, revision, &moved);
            },
        };

        _ = self.note(result);
        if (result != c.FOUNDRY_OK) {
            self.reportCode(result);
            return;
        }
        self.form = .none;
        // A command re-parses, so the selection the service re-resolved is the only one
        // that still means anything.  Adopt it, and let the next frame find it by id.
        if (edit.has_record != c.FOUNDRY_FALSE) {
            self.selected_record = edit.record.hash;
            self.has_record = true;
        }
    }

    /// New Package writes an ordinary manifest: a document, a `foundry:mod` record and the
    /// three fields the schema requires.  Every step is a command the table already has,
    /// and a failure at any of them leaves the earlier ones in the history to undo.
    fn createPackage(self: *Client, workspace: Workspace, revision: u64, edit: *c.FoundryAuthorEdit) Result {
        var document: Document = .{ .bits = 0 };
        var at = revision;
        var code = self.api.author_document_create.?(workspace, at, string(manifest_document), &document);
        if (code == c.FOUNDRY_ERR_ALREADY_EXISTS) {
            document = self.documentNamed(workspace, manifest_document) orelse return code;
        } else if (code != c.FOUNDRY_OK) {
            return code;
        }
        at = self.currentRevision(workspace);

        code = self.api.author_record_create.?(
            document,
            at,
            string(manifest_schema),
            string(self.package_id.text()),
            edit,
        );
        if (code != c.FOUNDRY_OK) return code;

        const record = edit.selection;
        code = self.setField(record, "name", c.FOUNDRY_FIELD_STRING, self.package_name.text());
        if (code != c.FOUNDRY_OK) return code;
        code = self.setField(
            self.recordWithId(document, edit.record.hash) orelse return c.FOUNDRY_ERR_NOT_FOUND,
            "version",
            c.FOUNDRY_FIELD_U32,
            if (self.package_version.len != 0) self.package_version.text() else "1",
        );
        if (code != c.FOUNDRY_OK) return code;
        return self.setField(
            self.recordWithId(document, edit.record.hash) orelse return c.FOUNDRY_ERR_NOT_FOUND,
            "license",
            c.FOUNDRY_FIELD_STRING,
            self.package_license.text(),
        );
    }

    fn setField(self: *Client, record: Node, name: []const u8, field_type: i32, text: []const u8) Result {
        var node: Node = .{ .bits = 0 };
        const found = self.api.author_node_field.?(record, string(name), &node);
        if (found != c.FOUNDRY_OK) return found;
        var value: Value = std.mem.zeroes(Value);
        value.field_type = field_type;
        value.text = string(text);
        var edit: c.FoundryAuthorEdit = std.mem.zeroes(c.FoundryAuthorEdit);
        const workspace = self.firstWorkspace() catch return c.FOUNDRY_ERR_UNAVAILABLE;
        return self.api.author_value_set.?(node, self.currentRevision(workspace), &value, &edit);
    }

    /// The destinations the host configured, counted afresh each frame: a grant belongs
    /// to the workspace, and the workspace is the thing that can be closed and reopened.
    fn exportCount(self: *Client) u32 {
        const workspace = self.firstWorkspace() catch return 0;
        var cursor: Cursor = beginCursor();
        var info: c.FoundryAuthorExportInfo = std.mem.zeroes(c.FoundryAuthorExportInfo);
        var count: u32 = 0;
        while (count < max_documents and
            self.api.author_export_next.?(workspace, &cursor, &info) == c.FOUNDRY_OK) count += 1;
        return count;
    }

    fn runBuild(self: *Client, workspace: Workspace, revision: u64) Result {
        var next: Build = .{ .bits = 0 };
        const code = self.api.author_build.?(workspace, revision, &next);
        if (code != c.FOUNDRY_OK) return code;
        // Two builds may live at once, and a preview is holding one of them.  Release the
        // previous build unless that is the one the loaded content is reading from.
        if (self.has_build and !(self.has_previewed and self.previewed.bits == self.build.bits)) {
            _ = self.api.author_build_release.?(self.build);
        }
        self.build = next;
        self.has_build = true;
        return c.FOUNDRY_OK;
    }

    fn runReload(self: *Client) Result {
        if (!self.has_build) return c.FOUNDRY_ERR_NOT_FOUND;
        const code = self.api.author_preview_activate.?(self.build);
        if (code != c.FOUNDRY_OK) return code;
        if (self.has_previewed and self.previewed.bits != self.build.bits) {
            _ = self.api.author_build_release.?(self.previewed);
        }
        self.previewed = self.build;
        self.has_previewed = true;
        return c.FOUNDRY_OK;
    }

    // -- reading ------------------------------------------------------------------------

    fn refreshContent(self: *Client) void {
        var generation: u64 = 0;
        if (self.api.content_generation.?(&generation) != c.FOUNDRY_OK or generation == self.generation) return;
        self.generation = generation;
        self.text = .{};

        var record_id: c.FoundryContentId = .{ .hash = 0 };
        if (self.api.id_from_string.?(string("foundry:editor.screen"), &record_id) == c.FOUNDRY_OK) {
            var record: c.FoundryRecord = .{ .bits = 0 };
            if (self.api.content_find.?(record_id, &record) == c.FOUNDRY_OK) {
                inline for (@typeInfo(TextKey).@"enum".fields) |entry| {
                    const key: TextKey = @enumFromInt(entry.value);
                    self.copyText(record, key, entry.name);
                }
            }
        }

        var theme_id: c.FoundryContentId = .{ .hash = 0 };
        if (self.api.id_from_string.?(string("foundry:editor.theme"), &theme_id) != c.FOUNDRY_OK) return;
        var theme: c.FoundryTheme = .{ .bits = 0 };
        self.theme = if (self.api.ui_theme_resolve.?(theme_id, &theme) == c.FOUNDRY_OK) theme else null;
    }

    fn copyText(self: *Client, record: c.FoundryRecord, key: TextKey, field_name: []const u8) void {
        var field_index: u32 = 0;
        if (self.api.record_field_index.?(record, string(field_name), &field_index) != c.FOUNDRY_OK) return;
        const index = @intFromEnum(key);
        var needed: u64 = 0;
        const result = self.api.record_copy_string.?(
            record,
            field_index,
            &self.text.bytes[index],
            self.text.bytes[index].len,
            &needed,
        );
        if (result == c.FOUNDRY_OK) self.text.lengths[index] = @intCast(needed);
    }

    fn firstWorkspace(self: *Client) UiError!Workspace {
        var cursor: Cursor = beginCursor();
        var workspace: Workspace = .{ .bits = 0 };
        try ok(self.api.author_workspace_next.?(&cursor, &workspace));
        return workspace;
    }

    fn workspaceInfo(self: *Client) ?c.FoundryAuthorWorkspaceInfo {
        const workspace = self.firstWorkspace() catch return null;
        var info: c.FoundryAuthorWorkspaceInfo = std.mem.zeroes(c.FoundryAuthorWorkspaceInfo);
        if (self.api.author_workspace_info.?(workspace, &info) != c.FOUNDRY_OK) return null;
        return info;
    }

    fn currentRevision(self: *Client, workspace: Workspace) u64 {
        var revision: u64 = 0;
        _ = self.api.author_workspace_revision.?(workspace, &revision);
        return revision;
    }

    /// The selected document's handle.  A document handle is derived from its workspace and
    /// its index, so enumerating is cheap and nothing here is invalidated by a command.
    fn currentDocument(self: *Client) ?Document {
        const workspace = self.firstWorkspace() catch return null;
        var cursor: Cursor = beginCursor();
        var document: Document = .{ .bits = 0 };
        var at: u32 = 0;
        while (at <= self.selected_document and at < max_documents) : (at += 1) {
            if (self.api.author_document_next.?(workspace, &cursor, &document) != c.FOUNDRY_OK) return null;
        }
        return document;
    }

    fn documentNamed(self: *Client, workspace: Workspace, path: []const u8) ?Document {
        var cursor: Cursor = beginCursor();
        var document: Document = .{ .bits = 0 };
        var at: u32 = 0;
        while (at < max_documents) : (at += 1) {
            if (self.api.author_document_next.?(workspace, &cursor, &document) != c.FOUNDRY_OK) return null;
            var info: c.FoundryAuthorDocumentInfo = std.mem.zeroes(c.FoundryAuthorDocumentInfo);
            if (self.api.author_document_info.?(document, &info) != c.FOUNDRY_OK) return null;
            if (std.mem.eql(u8, span(info.path), path)) return document;
        }
        return null;
    }

    fn selectDocumentNamed(self: *Client, workspace: Workspace, path: []const u8) void {
        var cursor: Cursor = beginCursor();
        var document: Document = .{ .bits = 0 };
        var at: u32 = 0;
        while (at < max_documents) : (at += 1) {
            if (self.api.author_document_next.?(workspace, &cursor, &document) != c.FOUNDRY_OK) return;
            var info: c.FoundryAuthorDocumentInfo = std.mem.zeroes(c.FoundryAuthorDocumentInfo);
            if (self.api.author_document_info.?(document, &info) != c.FOUNDRY_OK) return;
            if (std.mem.eql(u8, span(info.path), path)) {
                self.selected_document = at;
                self.has_record = false;
                return;
            }
        }
    }

    fn recordCount(self: *Client, document: Document) u32 {
        var cursor: Cursor = beginCursor();
        var record: Node = .{ .bits = 0 };
        var count: u32 = 0;
        while (count < max_records and self.api.author_record_next.?(document, &cursor, &record) == c.FOUNDRY_OK) count += 1;
        return count;
    }

    /// The selected record, found by content id rather than kept as a handle.
    fn findRecord(self: *Client, document: Document) ?Node {
        if (!self.has_record) return null;
        return self.recordWithId(document, self.selected_record);
    }

    fn recordWithId(self: *Client, document: Document, id: u64) ?Node {
        var cursor: Cursor = beginCursor();
        var record: Node = .{ .bits = 0 };
        var at: u32 = 0;
        while (at < max_records) : (at += 1) {
            if (self.api.author_record_next.?(document, &cursor, &record) != c.FOUNDRY_OK) return null;
            var info: c.FoundryAuthorNodeInfo = std.mem.zeroes(c.FoundryAuthorNodeInfo);
            if (self.api.author_node_info.?(record, &info) != c.FOUNDRY_OK) return null;
            if (info.id.hash == id) return record;
        }
        return null;
    }

    /// The declaration a record was written against, found by its schema id.  A registry
    /// holds hashes; `author_schema_next` is where the words are.
    fn schemaNodeFor(self: *Client, schema_id: u64) ?SchemaNode {
        const workspace = self.firstWorkspace() catch return null;
        var cursor: Cursor = beginCursor();
        var schema: SchemaNode = .{ .bits = 0 };
        var at: u32 = 0;
        while (at < max_schema_rows) : (at += 1) {
            if (self.api.author_schema_next.?(workspace, &cursor, &schema) != c.FOUNDRY_OK) return null;
            var info: c.FoundryAuthorSchemaNodeInfo = std.mem.zeroes(c.FoundryAuthorSchemaNodeInfo);
            if (self.api.author_schema_node_info.?(schema, &info) != c.FOUNDRY_OK) return null;
            if (info.schema.hash == schema_id) return schema;
        }
        return null;
    }

    fn schemaChild(self: *Client, parent: ?SchemaNode, index: u32) ?SchemaNode {
        const handle = parent orelse return null;
        var child: SchemaNode = .{ .bits = 0 };
        if (self.api.author_schema_node_child.?(handle, index, &child) != c.FOUNDRY_OK) return null;
        return child;
    }

    /// A list's element type, from its declaration.  Without it an empty list could not be
    /// added to at all: the source says nothing about what belongs in it.
    fn elementType(self: *Client, list_schema: ?SchemaNode) i32 {
        const child = self.schemaChild(list_schema, 0) orelse return c.FOUNDRY_FIELD_STRING;
        var info: c.FoundryAuthorSchemaNodeInfo = std.mem.zeroes(c.FoundryAuthorSchemaNodeInfo);
        if (self.api.author_schema_node_info.?(child, &info) != c.FOUNDRY_OK) return c.FOUNDRY_FIELD_STRING;
        return info.field_type;
    }

    fn presenceText(self: *Client, info: c.FoundryAuthorNodeInfo) []const u8 {
        return self.text.get(switch (info.presence) {
            c.FOUNDRY_AUTHOR_REQUIRED => .required,
            c.FOUNDRY_AUTHOR_OPTIONAL => .optional,
            c.FOUNDRY_AUTHOR_DEFAULT => .defaulted,
            else => .element,
        });
    }

    fn passes(self: *const Client, name: []const u8) bool {
        const needle = self.filter.text();
        if (needle.len == 0) return true;
        return std.mem.indexOf(u8, name, needle) != null;
    }

    /// The buffer this field is edited in, seeded from the canonical spelling and reseeded
    /// whenever the revision moves.  Slots are recycled round-robin; a form showing more
    /// fields than there are slots keeps the ones nearest the top of the panel.
    fn slotFor(self: *Client, key: u64, seed: []const u8) *FieldSlot {
        for (&self.fields) |*slot| {
            if (slot.used and slot.key == key) {
                if (slot.revision != self.revision) {
                    slot.revision = self.revision;
                    const n = @min(seed.len, slot.bytes.len);
                    @memcpy(slot.bytes[0..n], seed[0..n]);
                    slot.len = n;
                }
                return slot;
            }
        }
        const index = self.field_next % max_field_buffers;
        self.field_next +%= 1;
        const slot = &self.fields[index];
        slot.* = .{ .key = key, .revision = self.revision, .used = true };
        const n = @min(seed.len, slot.bytes.len);
        @memcpy(slot.bytes[0..n], seed[0..n]);
        slot.len = n;
        return slot;
    }

    /// A refusal, said as the code the table returned.  A number rather than a borrowed
    /// message: every string the boundary hands back expires before the next frame.
    fn reportCode(self: *Client, result: Result) void {
        const line = std.fmt.bufPrint(&self.status, "refused {d}", .{@as(i64, result)}) catch {
            self.status_len = 0;
            return;
        };
        self.status_len = line.len;
    }

    fn report(self: *Client, what: []const u8, number: u32) void {
        const line = std.fmt.bufPrint(&self.status, "{s} {d}", .{ what, number }) catch {
            self.status_len = 0;
            return;
        };
        self.status_len = line.len;
    }

    // -- widget helpers -----------------------------------------------------------------

    fn panel(self: *Client, value: u64, bounds: Rect) UiError!void {
        try ok(self.api.ui_begin_panel.?(uid(value), &bounds));
    }
    fn endPanel(self: *Client) UiError!void {
        try ok(self.api.ui_end_panel.?());
    }
    fn row(self: *Client, value: u64, height: f32) UiError!void {
        try ok(self.api.ui_begin_row.?(uid(value), height));
    }
    fn endRow(self: *Client) UiError!void {
        try ok(self.api.ui_end_row.?());
    }
    fn label(self: *Client, value: []const u8) UiError!void {
        try ok(self.api.ui_label.?(string(value)));
    }
    fn spacer(self: *Client, value: f32) UiError!void {
        try ok(self.api.ui_spacer.?(value));
    }
    fn separator(self: *Client) UiError!void {
        try ok(self.api.ui_separator.?());
    }
    fn indentedLabel(self: *Client, depth: u8, value: []const u8) UiError!void {
        if (depth != 0) try self.spacer(@as(f32, @floatFromInt(depth)) * 14);
        try self.label(value);
    }
    fn remaining(self: *Client) UiError!Rect {
        var rect: Rect = .{};
        try ok(self.api.ui_region_remaining.?(&rect));
        return rect;
    }
    fn style(self: *Client) UiError!c.FoundryUiStyle {
        var value: c.FoundryUiStyle = std.mem.zeroes(c.FoundryUiStyle);
        try ok(self.api.ui_style_get.?(&value));
        return value;
    }
    fn button(self: *Client, value: u64, key: TextKey) UiError!bool {
        var pressed: Bool = c.FOUNDRY_FALSE;
        try ok(self.api.ui_button.?(uid(value), string(self.text.get(key)), &pressed));
        return pressed != c.FOUNDRY_FALSE;
    }
    /// A button that is visible whether or not it may be used, because a command that
    /// vanishes teaches nobody why it is unavailable.
    fn command(self: *Client, value: u64, key: TextKey, enabled: bool) UiError!bool {
        if (enabled) return self.button(value, key);
        try ok(self.api.ui_begin_disabled.?());
        defer _ = self.api.ui_end_disabled.?();
        _ = try self.button(value, key);
        return false;
    }
    fn field(self: *Client, value: u64, buffer: []u8, len: *u64) UiError!bool {
        var changed: Bool = c.FOUNDRY_FALSE;
        try ok(self.api.ui_text_field.?(uid(value), buffer.ptr, buffer.len, len, &changed));
        return changed != c.FOUNDRY_FALSE;
    }

    fn note(self: *Client, result: Result) Result {
        self.observation.last_result = result;
        return result;
    }
};

const UiError = error{
    InvalidArgument,
    InvalidHandle,
    NotFound,
    Unavailable,
    Unsupported,
    AlreadyExists,
    Limit,
    Refused,
    OutOfMemory,
    Internal,
    End,
};

fn ok(result: Result) UiError!void {
    return switch (result) {
        c.FOUNDRY_OK => {},
        c.FOUNDRY_END => error.End,
        c.FOUNDRY_ERR_INVALID_ARGUMENT => error.InvalidArgument,
        c.FOUNDRY_ERR_INVALID_HANDLE => error.InvalidHandle,
        c.FOUNDRY_ERR_NOT_FOUND => error.NotFound,
        c.FOUNDRY_ERR_UNAVAILABLE => error.Unavailable,
        c.FOUNDRY_ERR_UNSUPPORTED => error.Unsupported,
        c.FOUNDRY_ERR_ALREADY_EXISTS => error.AlreadyExists,
        c.FOUNDRY_ERR_LIMIT => error.Limit,
        c.FOUNDRY_ERR_REFUSED => error.Refused,
        c.FOUNDRY_ERR_OUT_OF_MEMORY => error.OutOfMemory,
        else => error.Internal,
    };
}

/// Widget identity is the field's *path*, not its row number, so focus and a caret survive
/// a sibling being added above.  The salts separate the controls that share a path.
const salt_control: u64 = 0x9E37_79B9_7F4A_7C15;
const salt_apply: u64 = 0xC2B2_AE3D_27D4_EB4F;
const salt_reset: u64 = 0x1656_67B1_9E37_79F9;
const salt_add: u64 = 0xD6E8_FEB8_6659_FD93;
const salt_remove: u64 = 0xA0761D6478BD642F;
const salt_up: u64 = 0xE7037ED1A0B428DB;
const salt_down: u64 = 0x8EBC6AF09C88C6E3;
const salt_element: u64 = 0x589965CC75374CC3;

fn hashOf(parent: u64, index: u32) u64 {
    return (parent ^ (@as(u64, index) +% 0x9E37_79B9_7F4A_7C15)) *% 0x1000_0000_01B3;
}

fn beginCursor() Cursor {
    return .{ .bits = 0 };
}

fn uid(value: u64) UiId {
    return .{ .bits = value };
}

fn string(value: []const u8) Str {
    return .{ .ptr = value.ptr, .len = value.len };
}

fn span(value: Str) []const u8 {
    if (value.ptr == null or value.len > std.math.maxInt(usize)) return "";
    return value.ptr[0..@intCast(value.len)];
}

/// How wide the kernel will draw `text`, from the metrics the table reports: every
/// character one cell of the grid, and the letter spacing between them.
fn measure(style: c.FoundryUiStyle, text: []const u8) f32 {
    const count = std.unicode.utf8CountCodepoints(text) catch text.len;
    if (count == 0) return 0;
    const cell = style.font.cell.x * style.text_scale;
    return @as(f32, @floatFromInt(count)) * (cell + style.font.letter_spacing) - style.font.letter_spacing;
}

fn boolOut(value: bool) Bool {
    return if (value) c.FOUNDRY_TRUE else c.FOUNDRY_FALSE;
}

test "the client is compiled against the complete v4 header" {
    try std.testing.expect(@sizeOf(Api) > @sizeOf(c.FoundryApi_v3));
    try std.testing.expectEqual(@as(u32, 4), c.FOUNDRY_API_VERSION_4);
}

test "borrowed header strings are read without sentinel assumptions" {
    const value = "editor";
    try std.testing.expectEqualStrings(value, span(string(value)));
}

test "a field path, not a row number, names a control" {
    // Two fields at the same index of different records must not share a widget, or a
    // caret would follow the selection from one record into another.
    try std.testing.expect(hashOf(11, 2) != hashOf(12, 2));
    try std.testing.expect(hashOf(11, 2) != hashOf(11, 3));
    // And the same path is the same control on every frame, which is what keeps focus.
    try std.testing.expectEqual(hashOf(hashOf(7, 1), 4), hashOf(hashOf(7, 1), 4));
}

test "every screen string the editor draws is a field of its content record" {
    // The record's schema is written by hand in `tools/editor/content/editor.fdt`; this is
    // the half of that agreement the code can state. A key with no field reads as empty,
    // which is a blank button rather than a crash, so the check has to be explicit.
    try std.testing.expect(text_count > 60);
    inline for (@typeInfo(TextKey).@"enum".fields) |field| {
        try std.testing.expect(field.name.len > 0);
        try std.testing.expect(field.name.len < 32);
    }
}
