//! The standalone editor's unprivileged client.
//!
//! It sees only `foundry.h` through `foundry_api` and `std` utilities.  Every workspace,
//! source, dependency, preview, schema, asset, diagnostic, log line and widget below crosses
//! `FoundryApi_v4`; paths, service handles and implementation modules never do.  Step 6 is an
//! inspector.  Commands and editable forms arrive in Step 7.

const std = @import("std");
const c = @import("foundry_api").c;

pub const Api = c.FoundryApi_v4;

const Result = c.FoundryResult;
const Cursor = c.FoundryCursor;
const Rect = c.FoundryUiRect;
const Str = c.FoundryStr;
const UiId = c.FoundryUiId;

const max_rows: u32 = 256;
const max_depth: u8 = 4;

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
    last_result: Result = c.FOUNDRY_OK,
};

const TextKey = enum {
    title,
    workspace,
    documents,
    source,
    dependencies,
    preview,
    schemas,
    assets,
    diagnostics,
    output_log,
    no_workspace,
    no_selection,
    status_ready,
    status_read_only,
    dirty,
    clean,
    unavailable,
};

const text_count = @typeInfo(TextKey).@"enum".fields.len;
const Text = struct {
    bytes: [text_count][64]u8 = @splat(@splat(0)),
    lengths: [text_count]u8 = @splat(0),

    fn get(self: *const Text, key: TextKey) []const u8 {
        const index = @intFromEnum(key);
        return self.bytes[index][0..self.lengths[index]];
    }

    fn set(self: *Text, key: TextKey, value: []const u8) void {
        const index = @intFromEnum(key);
        const length = @min(value.len, self.bytes[index].len);
        @memcpy(self.bytes[index][0..length], value[0..length]);
        self.lengths[index] = @intCast(length);
    }
};

const Tab = enum(u32) { source, dependencies, preview, schemas, assets };

pub const Client = struct {
    api: *const Api,
    generation: u64 = 0,
    text: Text = .{},
    theme: ?c.FoundryTheme = null,
    tab: Tab = .source,
    selected_document: u32 = 0,
    observation: Observation = .{},

    pub fn init(api: *const Api) error{WrongApi}!Client {
        if (api.version != c.FOUNDRY_API_VERSION_4 or api.size < @sizeOf(Api)) return error.WrongApi;
        return .{ .api = api };
    }

    /// Builds and activates the first granted workspace using only public calls.  The host
    /// chooses every root and capability before this client exists.
    pub fn requestPreview(self: *Client) Result {
        var cursor: Cursor = beginCursor();
        var workspace: c.FoundryWorkspace = .{ .bits = 0 };
        var result = self.api.author_workspace_next.?(&cursor, &workspace);
        if (result != c.FOUNDRY_OK) return self.note(result);

        var revision: u64 = 0;
        result = self.api.author_workspace_revision.?(workspace, &revision);
        if (result != c.FOUNDRY_OK) return self.note(result);

        var build: c.FoundryBuild = .{ .bits = 0 };
        result = self.api.author_build.?(workspace, revision, &build);
        if (result != c.FOUNDRY_OK) return self.note(result);
        result = self.api.author_preview_activate.?(build);
        return self.note(result);
    }

    /// A bounded, non-rendering traversal used by the null smoke run. It asks every Step 6
    /// browser its real public question once, so the proof does not depend on synthetic
    /// pointer input selecting five tabs in three frames.
    pub fn inspect(self: *Client) Observation {
        var seen: Observation = .{};
        var workspaces: Cursor = beginCursor();
        var workspace: c.FoundryWorkspace = .{ .bits = 0 };
        while (seen.workspaces < max_rows and self.api.author_workspace_next.?(&workspaces, &workspace) == c.FOUNDRY_OK) {
            seen.workspaces += 1;

            var documents: Cursor = beginCursor();
            var document: c.FoundryDocument = .{ .bits = 0 };
            while (seen.documents < max_rows and self.api.author_document_next.?(workspace, &documents, &document) == c.FOUNDRY_OK) {
                seen.documents += 1;
                var records: Cursor = beginCursor();
                var source: c.FoundrySourceNode = .{ .bits = 0 };
                while (seen.source_records < max_rows and self.api.author_record_next.?(document, &records, &source) == c.FOUNDRY_OK) {
                    seen.source_records += 1;
                    var info: c.FoundryAuthorNodeInfo = std.mem.zeroes(c.FoundryAuthorNodeInfo);
                    _ = self.api.author_node_info.?(source, &info);
                }
            }

            var dependencies: Cursor = beginCursor();
            var package: c.FoundryAuthorPackageInfo = std.mem.zeroes(c.FoundryAuthorPackageInfo);
            while (seen.dependencies < max_rows and self.api.author_dependency_next.?(workspace, &dependencies, &package) == c.FOUNDRY_OK) {
                seen.dependencies += 1;
                var records: Cursor = beginCursor();
                var dependency: c.FoundrySourceNode = .{ .bits = 0 };
                while (seen.dependency_records < max_rows and self.api.author_dependency_record_next.?(workspace, package.index, &records, &dependency) == c.FOUNDRY_OK) {
                    seen.dependency_records += 1;
                }
            }

            var preview: Cursor = beginCursor();
            var preview_record: c.FoundrySourceNode = .{ .bits = 0 };
            while (seen.preview_records < max_rows and self.api.author_preview_record_next.?(workspace, &preview, &preview_record) == c.FOUNDRY_OK) {
                seen.preview_records += 1;
            }

            var schemas: Cursor = beginCursor();
            var schema: c.FoundrySchemaNode = .{ .bits = 0 };
            while (seen.schemas < max_rows and self.api.author_schema_next.?(workspace, &schemas, &schema) == c.FOUNDRY_OK) {
                seen.schemas += 1;
                var info: c.FoundryAuthorSchemaNodeInfo = std.mem.zeroes(c.FoundryAuthorSchemaNodeInfo);
                _ = self.api.author_schema_node_info.?(schema, &info);
            }

            var diagnostics: Cursor = beginCursor();
            var diagnostic: c.FoundryAuthorDiagnostic = std.mem.zeroes(c.FoundryAuthorDiagnostic);
            while (seen.diagnostics < 64 and self.api.author_diagnostic_next.?(workspace, &diagnostics, &diagnostic) == c.FOUNDRY_OK) {
                seen.diagnostics += 1;
            }
        }

        var assets: Cursor = beginCursor();
        var loaded_asset: c.FoundryAsset = .{ .bits = 0 };
        while (seen.assets < max_rows and self.api.asset_next.?(&assets, &loaded_asset) == c.FOUNDRY_OK) seen.assets += 1;

        var logs: Cursor = beginCursor();
        var record: c.FoundryLogRecord = std.mem.zeroes(c.FoundryLogRecord);
        while (seen.logs < 64 and self.api.log_next.?(&logs, &record) == c.FOUNDRY_OK) seen.logs += 1;
        self.observation = seen;
        return seen;
    }

    /// Describes one fixed-region editor frame.  It intentionally performs no authoring
    /// command: Step 6 establishes the host and the boundary; Step 7 supplies forms.
    pub fn frame(self: *Client, viewport: Rect) void {
        self.observation = .{};
        self.refreshContent();

        const pushed = if (self.theme) |theme|
            self.api.ui_theme_push.?(theme) == c.FOUNDRY_OK
        else
            false;
        if (self.theme != null and !pushed) self.theme = null;
        defer if (pushed) {
            _ = self.api.ui_theme_pop.?();
        };

        if (self.api.ui_begin.?(&viewport) != c.FOUNDRY_OK) return;
        defer {
            const ended = self.api.ui_end.?();
            if (ended != c.FOUNDRY_OK) _ = self.note(ended);
        }

        self.describe(viewport) catch {
            _ = self.note(c.FOUNDRY_ERR_INTERNAL);
        };
    }

    fn describe(self: *Client, viewport: Rect) UiError!void {
        const toolbar_h: f32 = 42;
        const status_h: f32 = 24;
        const output_h: f32 = @min(176, @max(96, viewport.h * 0.25));
        const left_w: f32 = @min(320, @max(220, viewport.w * 0.24));
        const body_h = @max(0, viewport.h - toolbar_h - output_h - status_h);

        try self.panel(1, .{ .x = 0, .y = 0, .w = viewport.w, .h = toolbar_h });
        try self.row(2, toolbar_h - 8);
        try self.label(self.text.get(.title));
        try self.spacer(18);
        try self.label(self.text.get(.workspace));
        try self.endRow();
        try self.endPanel();

        try self.panel(10, .{ .x = 0, .y = toolbar_h, .w = left_w, .h = body_h });
        try self.leftPane();
        try self.endPanel();

        try self.panel(20, .{ .x = left_w, .y = toolbar_h, .w = @max(0, viewport.w - left_w), .h = body_h });
        try self.tabs();
        switch (self.tab) {
            .source => try self.sourcePane(),
            .dependencies => try self.dependencyPane(),
            .preview => try self.previewPane(),
            .schemas => try self.schemaPane(),
            .assets => try self.assetPane(),
        }
        try self.endPanel();

        try self.panel(30, .{ .x = 0, .y = toolbar_h + body_h, .w = viewport.w, .h = output_h });
        try self.outputPane();
        try self.endPanel();

        try self.panel(40, .{ .x = 0, .y = viewport.h - status_h, .w = viewport.w, .h = status_h });
        try self.statusPane();
        try self.endPanel();
    }

    fn leftPane(self: *Client) UiError!void {
        var workspaces: Cursor = beginCursor();
        var workspace: c.FoundryWorkspace = .{ .bits = 0 };
        while (self.observation.workspaces < max_rows) {
            const result = self.api.author_workspace_next.?(&workspaces, &workspace);
            if (result == c.FOUNDRY_END) break;
            try ok(result);
            self.observation.workspaces += 1;

            var info: c.FoundryAuthorWorkspaceInfo = std.mem.zeroes(c.FoundryAuthorWorkspaceInfo);
            try ok(self.api.author_workspace_info.?(workspace, &info));
            try self.label(span(info.package_name));
            try self.separator();
            try self.label(self.text.get(.documents));

            var documents: Cursor = beginCursor();
            var document: c.FoundryDocument = .{ .bits = 0 };
            var at: u32 = 0;
            while (self.observation.documents < max_rows) : (at += 1) {
                const next = self.api.author_document_next.?(workspace, &documents, &document);
                if (next == c.FOUNDRY_END) break;
                try ok(next);
                self.observation.documents += 1;
                var document_info: c.FoundryAuthorDocumentInfo = std.mem.zeroes(c.FoundryAuthorDocumentInfo);
                try ok(self.api.author_document_info.?(document, &document_info));
                var clicked: c.FoundryBool = c.FOUNDRY_FALSE;
                try ok(self.api.ui_selectable.?(id(100 + at), document_info.path, boolOut(at == self.selected_document), &clicked));
                if (clicked != c.FOUNDRY_FALSE) self.selected_document = at;
            }
        }
        if (self.observation.workspaces == 0) try self.label(self.text.get(.no_workspace));
    }

    fn tabs(self: *Client) UiError!void {
        const labels = [_]Str{
            string(self.text.get(.source)),
            string(self.text.get(.dependencies)),
            string(self.text.get(.preview)),
            string(self.text.get(.schemas)),
            string(self.text.get(.assets)),
        };
        var selected: u32 = @intFromEnum(self.tab);
        try ok(self.api.ui_tabs.?(id(200), &labels, labels.len, &selected));
        self.tab = std.enums.fromInt(Tab, selected) orelse .source;
        try self.separator();
    }

    fn sourcePane(self: *Client) UiError!void {
        const workspace = try self.firstWorkspace();
        var documents: Cursor = beginCursor();
        var document: c.FoundryDocument = .{ .bits = 0 };
        var at: u32 = 0;
        while (at <= self.selected_document and at < max_rows) : (at += 1) {
            const result = self.api.author_document_next.?(workspace, &documents, &document);
            if (result == c.FOUNDRY_END) return self.label(self.text.get(.no_selection));
            try ok(result);
        }

        var records: Cursor = beginCursor();
        var record_node: c.FoundrySourceNode = .{ .bits = 0 };
        while (self.observation.source_records < max_rows) {
            const result = self.api.author_record_next.?(document, &records, &record_node);
            if (result == c.FOUNDRY_END) break;
            try ok(result);
            self.observation.source_records += 1;
            try self.node(record_node, 0);
        }
    }

    fn dependencyPane(self: *Client) UiError!void {
        const workspace = try self.firstWorkspace();
        var packages: Cursor = beginCursor();
        var package: c.FoundryAuthorPackageInfo = std.mem.zeroes(c.FoundryAuthorPackageInfo);
        while (self.observation.dependencies < max_rows) {
            const result = self.api.author_dependency_next.?(workspace, &packages, &package);
            if (result == c.FOUNDRY_END) break;
            try ok(result);
            self.observation.dependencies += 1;
            try self.label(span(package.name));

            var records: Cursor = beginCursor();
            var record_node: c.FoundrySourceNode = .{ .bits = 0 };
            var in_package: u32 = 0;
            while (in_package < max_rows) : (in_package += 1) {
                const next = self.api.author_dependency_record_next.?(workspace, package.index, &records, &record_node);
                if (next == c.FOUNDRY_END) break;
                try ok(next);
                self.observation.dependency_records += 1;
                try self.node(record_node, 1);
            }
        }
    }

    fn previewPane(self: *Client) UiError!void {
        const workspace = try self.firstWorkspace();
        var info: c.FoundryAuthorPreviewInfo = std.mem.zeroes(c.FoundryAuthorPreviewInfo);
        const state = self.api.author_preview_info.?(workspace, &info);
        if (state != c.FOUNDRY_OK) {
            try self.label(self.text.get(.unavailable));
            return;
        }
        var records: Cursor = beginCursor();
        var record_node: c.FoundrySourceNode = .{ .bits = 0 };
        while (self.observation.preview_records < max_rows) {
            const result = self.api.author_preview_record_next.?(workspace, &records, &record_node);
            if (result == c.FOUNDRY_END or result == c.FOUNDRY_ERR_NOT_FOUND) break;
            try ok(result);
            self.observation.preview_records += 1;
            try self.node(record_node, 0);
        }
    }

    fn schemaPane(self: *Client) UiError!void {
        const workspace = try self.firstWorkspace();
        var cursor: Cursor = beginCursor();
        var schema: c.FoundrySchemaNode = .{ .bits = 0 };
        while (self.observation.schemas < max_rows) {
            const result = self.api.author_schema_next.?(workspace, &cursor, &schema);
            if (result == c.FOUNDRY_END) break;
            try ok(result);
            self.observation.schemas += 1;
            try self.schemaNode(schema, 0);
        }
    }

    fn assetPane(self: *Client) UiError!void {
        var cursor: Cursor = beginCursor();
        var asset: c.FoundryAsset = .{ .bits = 0 };
        while (self.observation.assets < max_rows) {
            const result = self.api.asset_next.?(&cursor, &asset);
            if (result == c.FOUNDRY_END) break;
            try ok(result);
            self.observation.assets += 1;
            var content_id: c.FoundryContentId = .{ .hash = 0 };
            try ok(self.api.asset_content_id.?(asset, &content_id));
            var name: Str = string("");
            if (self.api.id_to_string.?(content_id, &name) == c.FOUNDRY_OK) try self.label(span(name));
        }
    }

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
            while (self.observation.diagnostics < 64) {
                const result = self.api.author_diagnostic_next.?(workspace, &cursor, &diagnostic);
                if (result == c.FOUNDRY_END) break;
                if (result != c.FOUNDRY_OK) break;
                self.observation.diagnostics += 1;
                try self.label(span(diagnostic.message));
            }
        } else |_| {}

        var logs: Cursor = beginCursor();
        var record: c.FoundryLogRecord = std.mem.zeroes(c.FoundryLogRecord);
        while (self.observation.logs < 64) {
            const result = self.api.log_next.?(&logs, &record);
            if (result == c.FOUNDRY_END) break;
            if (result != c.FOUNDRY_OK) break;
            self.observation.logs += 1;
            try self.label(span(record.text));
        }
    }

    fn statusPane(self: *Client) UiError!void {
        try self.row(401, 20);
        try self.label(self.text.get(.status_ready));
        try self.spacer(18);
        try self.label(self.text.get(.status_read_only));
        if (self.firstWorkspace()) |workspace| {
            var info: c.FoundryAuthorWorkspaceInfo = std.mem.zeroes(c.FoundryAuthorWorkspaceInfo);
            if (self.api.author_workspace_info.?(workspace, &info) == c.FOUNDRY_OK) {
                try self.spacer(18);
                try self.label(self.text.get(if (info.dirty != c.FOUNDRY_FALSE) .dirty else .clean));
            }
        } else |_| {}
        try self.endRow();
    }

    fn node(self: *Client, handle: c.FoundrySourceNode, depth: u8) UiError!void {
        var info: c.FoundryAuthorNodeInfo = std.mem.zeroes(c.FoundryAuthorNodeInfo);
        try ok(self.api.author_node_info.?(handle, &info));
        try self.indentedLabel(depth, span(info.name));
        if (depth >= max_depth) return;
        const count = @min(info.child_count, max_rows);
        for (0..count) |index| {
            var child: c.FoundrySourceNode = .{ .bits = 0 };
            const result = self.api.author_node_child.?(handle, @intCast(index), &child);
            if (result != c.FOUNDRY_OK) break;
            try self.node(child, depth + 1);
        }
    }

    fn schemaNode(self: *Client, handle: c.FoundrySchemaNode, depth: u8) UiError!void {
        var info: c.FoundryAuthorSchemaNodeInfo = std.mem.zeroes(c.FoundryAuthorSchemaNodeInfo);
        try ok(self.api.author_schema_node_info.?(handle, &info));
        try self.indentedLabel(depth, span(info.name));
        if (depth >= 2) return;
        const count = @min(info.child_count, max_rows);
        for (0..count) |index| {
            var child: c.FoundrySchemaNode = .{ .bits = 0 };
            const result = self.api.author_schema_node_child.?(handle, @intCast(index), &child);
            if (result != c.FOUNDRY_OK) break;
            try self.schemaNode(child, depth + 1);
        }
    }

    fn indentedLabel(self: *Client, depth: u8, value: []const u8) UiError!void {
        if (depth != 0) try self.spacer(@as(f32, @floatFromInt(depth)) * 14);
        try self.label(value);
    }

    fn firstWorkspace(self: *Client) UiError!c.FoundryWorkspace {
        var cursor: Cursor = beginCursor();
        var workspace: c.FoundryWorkspace = .{ .bits = 0 };
        try ok(self.api.author_workspace_next.?(&cursor, &workspace));
        return workspace;
    }

    fn refreshContent(self: *Client) void {
        var generation: u64 = 0;
        if (self.api.content_generation.?(&generation) != c.FOUNDRY_OK or generation == self.generation) return;
        self.generation = generation;
        self.text = .{};

        var record_id: c.FoundryContentId = .{ .hash = 0 };
        if (self.api.id_from_string.?(string("foundry:editor.screen"), &record_id) == c.FOUNDRY_OK) {
            var record: c.FoundryRecord = .{ .bits = 0 };
            if (self.api.content_find.?(record_id, &record) == c.FOUNDRY_OK) {
                inline for (@typeInfo(TextKey).@"enum".fields) |field| {
                    const key: TextKey = @enumFromInt(field.value);
                    self.copyText(record, key, field.name);
                }
            }
        }

        var theme_id: c.FoundryContentId = .{ .hash = 0 };
        if (self.api.id_from_string.?(string("foundry:editor.theme"), &theme_id) != c.FOUNDRY_OK) return;
        var theme: c.FoundryTheme = .{ .bits = 0 };
        self.theme = if (self.api.ui_theme_resolve.?(theme_id, &theme) == c.FOUNDRY_OK) theme else null;
    }

    fn copyText(self: *Client, record: c.FoundryRecord, key: TextKey, field_name: []const u8) void {
        var field: u32 = 0;
        if (self.api.record_field_index.?(record, string(field_name), &field) != c.FOUNDRY_OK) return;
        const index = @intFromEnum(key);
        var needed: u64 = 0;
        const result = self.api.record_copy_string.?(
            record,
            field,
            &self.text.bytes[index],
            self.text.bytes[index].len,
            &needed,
        );
        if (result == c.FOUNDRY_OK) self.text.lengths[index] = @intCast(needed);
    }

    fn panel(self: *Client, value: u64, bounds: Rect) UiError!void {
        try ok(self.api.ui_begin_panel.?(id(value), &bounds));
    }
    fn endPanel(self: *Client) UiError!void {
        try ok(self.api.ui_end_panel.?());
    }
    fn row(self: *Client, value: u64, height: f32) UiError!void {
        try ok(self.api.ui_begin_row.?(id(value), height));
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

fn beginCursor() Cursor {
    return .{ .bits = 0 };
}

fn id(value: u64) UiId {
    return .{ .bits = value };
}

fn string(value: []const u8) Str {
    return .{ .ptr = value.ptr, .len = value.len };
}

fn span(value: Str) []const u8 {
    if (value.ptr == null or value.len > std.math.maxInt(usize)) return "";
    return value.ptr[0..@intCast(value.len)];
}

fn boolOut(value: bool) c.FoundryBool {
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
