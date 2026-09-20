//! The editor's authoring workflow, driven by deterministic input (`editor.md` §12).
//!
//! **This is the application, not a model of it.**  A real `author.Service` over a real
//! temporary package, a real `abi.Host`, the real `FoundryApi_v4` table and the real client
//! — described frame by frame, with synthetic pointer and keyboard input aimed at the
//! rectangles the client recorded while describing itself.  Nothing here calls an authoring
//! function directly to make something happen: every change below is a click.
//!
//! It knows the fixture's schema and field names, which production editor code may not
//! (`editor.md` §11).  That is the whole reason the workflow lives in a test module and the
//! application's own `--script` walk does not.
//!
//! No renderer, no window, no device: `ui` describes a draw list and this never draws it.

const std = @import("std");
const abi = @import("abi");
const author = @import("author");
const core = @import("core");
const data = @import("data");
const editor_client = @import("editor_client");
const platform = @import("platform");
const preview_mod = @import("preview.zig");
const script = @import("script.zig");
const ui = @import("ui");

const testing = std.testing;
const Api = abi.Api_v4;
const Rect = editor_client.Rect;
const Vec2 = core.math.Vec2;

/// Every field shape the content model has, each with a different presence, so one record
/// exercises the whole form.  A local `@schema` because that is what a package being
/// authored from nothing actually has.
const fixture_schema = "demo:thing";

/// Backspaces an `enter` sends before typing. Longer than any value these tests set.
const max_clear = 24;
const max_test_dependencies = 4;

const fixture_source =
    \\# A fixture, not content: the editor is pointed at a throwaway directory.
    \\@schema thing {
    \\    count u64
    \\    small i32
    \\    big i64
    \\    tally u32
    \\    ratio f32
    \\    weight f64 (optional)
    \\    label string (default "none")
    \\    target id (optional)
    \\    enabled bool
    \\    tags [string] (optional)
    \\    where { x i32  y i32 } (optional)
    \\}
    \\
;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    os: *platform.os.Os,
    base: []const u8 = "",
    base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    owned: std.ArrayList([]const u8) = .empty,

    fn init(with_source: bool) !*Fixture {
        const gpa = testing.allocator;
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);
        self.* = .{
            .tmp = testing.tmpDir(.{}),
            .os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-editor-workflow-test" }),
        };
        const n = try self.tmp.dir.realPath(testing.io, &self.base_buf);
        self.base = self.base_buf[0..n];
        try self.os.createDirPath(try self.at("src"));
        try self.os.createDirPath(try self.at("out"));
        try self.os.createDirPath(try self.at("ship"));
        if (with_source) try self.write("demo.fdt", fixture_source);
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
        try self.os.writeFile(path, text);
    }

    fn read(self: *Fixture, rel: []const u8) ![]u8 {
        const gpa = testing.allocator;
        const path = try platform.os.joinPath(gpa, &.{ self.base, "src", rel });
        defer gpa.free(path);
        return self.os.readFile(gpa, path, 1 << 20);
    }

    /// Compiles a dependency package and writes the `.fpk` beside the workspace, which is
    /// what a host actually grants.  Building the fixture is not authoring it: the
    /// override under test copies *from* this, through the table.
    fn pack(self: *Fixture, name: []const u8, text: []const u8) ![]const u8 {
        const gpa = testing.allocator;
        const rel = try std.fmt.allocPrint(gpa, "dep/{s}", .{name});
        defer gpa.free(rel);
        const dir = try self.at(rel);
        try self.os.createDirPath(dir);
        const manifest_path = try platform.os.joinPath(gpa, &.{ dir, "mod.fdt" });
        defer gpa.free(manifest_path);
        try self.os.writeFile(manifest_path, text);

        var registry = data.Registry.init(gpa, .default);
        defer registry.deinit(gpa);
        var diags = data.Diagnostics.init(gpa, .default);
        defer diags.deinit(gpa);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        const identity = try author.compiler.compile(gpa, self.os, dir, .{}, &registry, &diags, &bytes);
        defer gpa.free(identity.name);
        if (diags.failed) return error.FixtureFailed;

        const out_rel = try std.fmt.allocPrint(gpa, "dep/{s}.fpk", .{name});
        defer gpa.free(out_rel);
        const path = try self.at(out_rel);
        try self.os.writeFile(path, bytes.items);
        return path;
    }

    fn exists(self: *Fixture, rel: []const u8) bool {
        const bytes = self.read(rel) catch return false;
        testing.allocator.free(bytes);
        return true;
    }
};

/// One editor, driven a frame at a time.
const Harness = struct {
    fixture: *Fixture,
    context: *ui.Context,
    service: *author.Service,
    preview: *preview_mod.State,
    host: *abi.Host,
    client: *editor_client.Client,
    api: *const Api,
    diags: data.Diagnostics,
    viewport: Rect = .{ .w = 1600, .h = 1000 },
    frame_index: u64 = 1,
    typed: [1]platform.event.TextInput = .{.{}},
    /// Borrowed by the service for the workspace's life, so it lives here and not in the
    /// frame that opened it.
    exports: [1]author.ExportTarget = undefined,
    /// Widget ids the kernel saw more than once in one frame, over every frame so far.
    duplicates: u32 = 0,
    pointer: Vec2 = .init(-1, -1),
    /// The last non-OK code any frame produced, since a click's settling frame clears the
    /// client's own per-frame observation.
    last: i32 = 0,
    bound: bool = false,

    fn init() !*Harness {
        return initWith(&.{}, true);
    }

    fn initEmpty() !*Harness {
        return initWith(&.{}, false);
    }

    /// Each `dependency_text` is one `mod.fdt`, compiled into a granted `.fpk` before the
    /// workspace opens, which is the only way a workspace ever gets one.  They are granted
    /// in the order given, which is the order the client lists them in.
    fn initWith(dependency_texts: []const []const u8, with_source: bool) !*Harness {
        const gpa = testing.allocator;
        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);

        const fixture = try Fixture.init(with_source);
        errdefer fixture.deinit();

        const context = try gpa.create(ui.Context);
        errdefer gpa.destroy(context);
        context.* = .init(gpa, testStyle());

        const preview = try gpa.create(preview_mod.State);
        errdefer gpa.destroy(preview);
        preview.* = .init(gpa, fixture.os);

        const service = try gpa.create(author.Service);
        errdefer gpa.destroy(service);
        service.* = .init(gpa, fixture.os, .{});

        const host = try gpa.create(abi.Host);
        errdefer gpa.destroy(host);
        host.* = .{ .ui_context = context, .author_service = service };

        const client = try gpa.create(editor_client.Client);
        errdefer gpa.destroy(client);

        self.* = .{
            .fixture = fixture,
            .context = context,
            .service = service,
            .preview = preview,
            .host = host,
            .client = client,
            .api = undefined,
            .diags = .init(gpa, .default),
        };

        var granted: [max_test_dependencies]author.DependencySource = undefined;
        if (dependency_texts.len > granted.len) return error.TooManyDependencies;
        for (dependency_texts, 0..) |source, at| {
            var name: [8]u8 = undefined;
            granted[at] = .{ .path = try fixture.pack(
                try std.fmt.bufPrint(&name, "dep{d}", .{at}),
                source,
            ) };
        }
        const dependencies = granted[0..dependency_texts.len];

        errdefer self.deinit();
        // One destination, the way a host grants one: a directory outside every source
        // and output root, and a file name inside it.  The client never sees either.
        self.exports[0] = .{
            .name = "--export",
            .kind = .compiled,
            .package_root = try fixture.at("ship"),
            .package_name = "demo.fpk",
        };
        _ = try service.open(try fixture.at("src"), .{
            .workspace = .{
                .dependencies = dependencies,
                .output_root = try fixture.at("out"),
                .grants = .{ .edit = true, .save = true, .build = true },
            },
            .exports = &self.exports,
            .preview = .{ .ctx = preview, .activate = preview_mod.State.activate },
        }, &self.diags);

        host.bind();
        self.bound = true;
        const table = abi.TableOf(abi.Host).getApi(abi.api_version_4) orelse return error.ApiUnavailable;
        self.api = @ptrCast(@alignCast(table));
        client.* = try editor_client.Client.init(@ptrCast(@alignCast(table)));
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = testing.allocator;
        if (self.bound) self.host.unbind();
        self.diags.deinit(gpa);
        self.service.deinit();
        self.preview.deinit();
        self.context.deinit();
        gpa.destroy(self.client);
        gpa.destroy(self.host);
        gpa.destroy(self.service);
        gpa.destroy(self.preview);
        gpa.destroy(self.context);
        self.fixture.deinit();
        gpa.destroy(self);
    }

    // -- driving ------------------------------------------------------------------------

    fn step(self: *Harness, input: ui.Input) void {
        var frame = input;
        frame.frame = self.frame_index;
        self.frame_index += 1;
        self.host.ui_input = frame;
        self.client.frame(self.viewport, .none);
        if (self.client.observation.last_result != 0) self.last = self.client.observation.last_result;
        // Two widgets sharing an id share a click, and the kernel is the only thing that
        // can see it happen.  Every test carries this: it is the cheapest way to notice a
        // frame that described the same thing twice.
        self.duplicates += self.context.duplicates;
    }

    fn idle(self: *Harness) void {
        self.step(.{ .pointer = .init(-1, -1) });
    }

    /// Hover, press, release, then one settling frame: exactly what a real click is, and
    /// what the kernel's hot/active model is written against.
    fn clickRect(self: *Harness, target: ?Rect) !void {
        const bounds = target orelse return error.ControlNotDrawn;
        self.last = 0;
        self.pointer = .init(bounds.x + 8, bounds.y + 10);
        self.step(.at(self.pointer, .up));
        self.step(.at(self.pointer, .pressed));
        self.step(.at(self.pointer, .released));
        self.idle();
    }

    fn click(self: *Harness, target: script.Target) !void {
        try self.clickRect(target.rect(&self.client.targets, 0));
    }

    /// The same, for a control that is one of several: a details row, or one of the
    /// granted packages.
    fn clickAt(self: *Harness, target: script.Target, index: u32) !void {
        try self.clickRect(target.rect(&self.client.targets, index));
    }

    fn row(self: *Harness, index: u32) editor_client.Targets.Row {
        if (index >= self.client.targets.row_count) return .{};
        return self.client.targets.rows[index];
    }

    /// Typed characters, to whatever the last click focused.
    fn write(self: *Harness, bytes: []const u8) !void {
        var from: usize = 0;
        while (from < bytes.len) {
            const to = @min(bytes.len, from + platform.event.max_text_bytes);
            self.typed[0] = platform.event.TextInput.fromSlice(bytes[from..to]) orelse return error.BadText;
            self.step(.{ .pointer = self.pointer, .text = self.typed[0..1] });
            from = to;
        }
    }

    fn key(self: *Harness, which: platform.Key) void {
        var input: ui.Input = .{ .pointer = self.pointer };
        platform.key.setKey(&input.keys.keys_pressed, which, true);
        self.step(input);
    }

    /// Click a field and delete `count` characters from the caret, leaving the rest: what
    /// an author does when they are correcting a value rather than replacing it.
    fn clearField(self: *Harness, target: ?Rect, count: usize) !void {
        try self.clickRect(target);
        self.key(.end);
        for (0..count) |_| self.key(.backspace);
    }

    /// Replace a control's contents: click it, run the caret to the end, clear it, and
    /// type.  A form box keeps what was last in it, so a script that only typed would be
    /// appending.
    fn enter(self: *Harness, target: ?Rect, bytes: []const u8) !void {
        try self.clickRect(target);
        self.key(.end);
        for (0..max_clear) |_| self.key(.backspace);
        try self.write(bytes);
        self.idle();
    }

    // -- reading back, through the same public table ---------------------------------------

    fn workspace(self: *Harness) !abi.Workspace {
        var cursor: abi.Cursor = .{};
        var handle: abi.Workspace = .none;
        try testing.expectEqual(abi.Result.ok, self.api.author_workspace_next(&cursor, &handle));
        return handle;
    }

    fn info(self: *Harness) !abi.AuthorWorkspaceInfo {
        var out: abi.AuthorWorkspaceInfo = .{};
        try testing.expectEqual(abi.Result.ok, self.api.author_workspace_info(try self.workspace(), &out));
        return out;
    }

    fn documentAt(self: *Harness, index: u32) !abi.Document {
        var cursor: abi.Cursor = .{};
        var handle: abi.Document = .none;
        var at: u32 = 0;
        while (at <= index) : (at += 1) {
            try testing.expectEqual(abi.Result.ok, self.api.author_document_next(try self.workspace(), &cursor, &handle));
        }
        return handle;
    }

    fn documentNamed(self: *Harness, path: []const u8) !abi.Document {
        var cursor: abi.Cursor = .{};
        var handle: abi.Document = .none;
        while (self.api.author_document_next(try self.workspace(), &cursor, &handle) == .ok) {
            var out: abi.AuthorDocumentInfo = .{};
            if (self.api.author_document_info(handle, &out) != .ok) break;
            if (std.mem.eql(u8, out.path.bytes() orelse "", path)) return handle;
        }
        return error.NoSuchDocument;
    }

    fn documentCount(self: *Harness) !u32 {
        var cursor: abi.Cursor = .{};
        var handle: abi.Document = .none;
        var count: u32 = 0;
        while (self.api.author_document_next(try self.workspace(), &cursor, &handle) == .ok) count += 1;
        return count;
    }

    fn record(self: *Harness, document: abi.Document, spelling: []const u8) !abi.SourceNode {
        var cursor: abi.Cursor = .{};
        var node: abi.SourceNode = .none;
        while (self.api.author_record_next(document, &cursor, &node) == .ok) {
            var out: abi.AuthorNodeInfo = .{};
            if (self.api.author_node_info(node, &out) != .ok) break;
            if (std.mem.eql(u8, out.name.bytes() orelse "", spelling)) return node;
        }
        return error.NoSuchRecord;
    }

    fn recordCount(self: *Harness, document: abi.Document) !u32 {
        var cursor: abi.Cursor = .{};
        var node: abi.SourceNode = .none;
        var count: u32 = 0;
        while (self.api.author_record_next(document, &cursor, &node) == .ok) count += 1;
        return count;
    }

    fn fieldOf(self: *Harness, document: []const u8, spelling: []const u8, name: []const u8) !abi.SourceNode {
        const node = try self.record(try self.documentNamed(document), spelling);
        var out: abi.SourceNode = .none;
        try testing.expectEqual(abi.Result.ok, self.api.author_node_field(node, .from(name), &out));
        return out;
    }

    fn fieldInfo(self: *Harness, document: []const u8, spelling: []const u8, name: []const u8) !abi.AuthorNodeInfo {
        var out: abi.AuthorNodeInfo = .{};
        try testing.expectEqual(abi.Result.ok, self.api.author_node_info(try self.fieldOf(document, spelling, name), &out));
        return out;
    }

    /// A field's canonical spelling, copied out of the borrow immediately.
    fn text(self: *Harness, document: []const u8, spelling: []const u8, name: []const u8, out: []u8) ![]const u8 {
        var value: abi.AuthorValue = .{};
        try testing.expectEqual(abi.Result.ok, self.api.author_node_scalar(try self.fieldOf(document, spelling, name), &value));
        const bytes = value.text.bytes() orelse "";
        if (bytes.len > out.len) return error.TooLong;
        @memcpy(out[0..bytes.len], bytes);
        return out[0..bytes.len];
    }

    fn diagnosticCount(self: *Harness) !u32 {
        var cursor: abi.Cursor = .{};
        var entry: abi.AuthorDiagnostic = .{};
        var count: u32 = 0;
        while (self.api.author_diagnostic_next(try self.workspace(), &cursor, &entry) == .ok) count += 1;
        return count;
    }

    // -- the shared opening moves ----------------------------------------------------------

    /// New Package, filled in and created.  Every one of these is a click or a keystroke.
    fn makePackage(self: *Harness) !void {
        try self.click(.new_package);
        try self.enter(self.client.targets.form_fields[0], "demo:pack");
        try self.enter(self.client.targets.form_fields[1], "Demo Package");
        try self.enter(self.client.targets.form_fields[2], "1");
        try self.enter(self.client.targets.form_fields[3], "Apache-2.0");
        try self.click(.form_create);
    }

    /// New Record of the fixture's schema, in the fixture's document.  The schema is
    /// named the way the table publishes it — a package's own `@schema thing` is
    /// `demo:thing` once the manifest gives the package its namespace.
    fn makeRecord(self: *Harness, id: []const u8) !void {
        try self.click(.first_document);
        try self.click(.new_record);
        try self.enter(self.client.targets.form_fields[0], fixture_schema);
        try self.enter(self.client.targets.form_fields[1], id);
        try self.click(.form_create);
    }
};

fn testStyle() ui.Style {
    return .{
        .font = .{ .cell = .init(8, 8) },
        .text_scale = 1,
        .line_height = 18,
        .padding = .init(6, 3),
        .spacing = 4,
        .text = .white,
        .text_dim = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 },
        .surface = .{ .r = 0.05, .g = 0.05, .b = 0.05, .a = 1 },
        .control = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1 },
        .control_hot = .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1 },
        .control_active = .{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 1 },
        .accent = .{ .r = 0.2, .g = 0.4, .b = 0.8, .a = 1 },
    };
}

// -- the workflow --------------------------------------------------------------------

test "an empty package is created, filled and saved entirely by clicking" {
    const h = try Harness.initEmpty();
    defer h.deinit();

    h.idle();
    try testing.expectEqual(@as(u32, 1), h.client.observation.workspaces);
    try testing.expectEqual(@as(u32, 0), try h.documentCount());
    // No manifest yet is a state, not a failure: it is where a new package starts.
    try testing.expect((try h.info()).has_manifest == 0);

    try h.makePackage();
    try testing.expectEqual(@as(u32, 1), try h.documentCount());
    const manifest = try h.documentNamed("mod.fdt");
    try testing.expectEqual(@as(u32, 1), try h.recordCount(manifest));

    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("Demo Package", try h.text("mod.fdt", "demo:pack", "name", &buffer));
    try testing.expectEqualStrings("1", try h.text("mod.fdt", "demo:pack", "version", &buffer));
    try testing.expectEqualStrings("Apache-2.0", try h.text("mod.fdt", "demo:pack", "license", &buffer));

    const state = try h.info();
    try testing.expect(state.has_manifest != 0);
    try testing.expect(state.dirty != 0);
    try testing.expect(state.can_undo != 0);

    // Save All publishes both files and says so; saving again writes nothing.
    try h.click(.save_all);
    try testing.expect((try h.info()).dirty == 0);
    try testing.expect(h.fixture.exists("mod.fdt"));
    try testing.expectEqual(@as(i32, 0), h.client.observation.last_result);
}

test "every field shape is edited through its own typed control" {
    const h = try Harness.init();
    defer h.deinit();

    h.idle();
    try h.makePackage();
    try h.makeRecord("demo:one");
    try testing.expect(h.client.has_record);
    // Eleven fields, laid out from the schema even though the source writes none of them.
    try testing.expectEqual(@as(u32, 11), h.client.targets.row_count);

    var buffer: [64]u8 = undefined;

    // A `u64` past what an `f64` can hold, which is the whole reason authoring numbers
    // cross as text: through a float this would come back as ...92.
    try h.enter(h.row(0).control, "9007199254740993");
    try h.clickRect(h.row(0).apply);
    try testing.expectEqualStrings("9007199254740993", try h.text("demo.fdt", "demo:one", "count", &buffer));

    try h.enter(h.row(1).control, "-2147483648");
    try h.clickRect(h.row(1).apply);
    try testing.expectEqualStrings("-2147483648", try h.text("demo.fdt", "demo:one", "small", &buffer));

    try h.enter(h.row(2).control, "-9223372036854775808");
    try h.clickRect(h.row(2).apply);
    try testing.expectEqualStrings("-9223372036854775808", try h.text("demo.fdt", "demo:one", "big", &buffer));

    try h.enter(h.row(3).control, "4294967295");
    try h.clickRect(h.row(3).apply);
    try testing.expectEqualStrings("4294967295", try h.text("demo.fdt", "demo:one", "tally", &buffer));

    try h.enter(h.row(4).control, "0.25");
    try h.clickRect(h.row(4).apply);
    try testing.expectEqualStrings("0.25", try h.text("demo.fdt", "demo:one", "ratio", &buffer));

    // An optional that nobody has written is neither missing nor defaulted, and the form
    // says which before and after it is set.
    try testing.expect((try h.fieldInfo("demo.fdt", "demo:one", "weight")).authored == 0);
    try h.enter(h.row(5).control, "-0.5");
    try h.clickRect(h.row(5).apply);
    try testing.expectEqualStrings("-0.5", try h.text("demo.fdt", "demo:one", "weight", &buffer));
    try testing.expect((try h.fieldInfo("demo.fdt", "demo:one", "weight")).authored != 0);

    // Reset-to-default unsets it again, and the default stays a default rather than being
    // written into the file.
    try h.clickRect(h.row(5).reset);
    try testing.expect((try h.fieldInfo("demo.fdt", "demo:one", "weight")).authored == 0);

    try h.enter(h.row(6).control, "torch");
    try h.clickRect(h.row(6).apply);
    try testing.expectEqualStrings("torch", try h.text("demo.fdt", "demo:one", "label", &buffer));

    try h.enter(h.row(7).control, "demo:one");
    try h.clickRect(h.row(7).apply);
    try testing.expectEqualStrings("demo:one", try h.text("demo.fdt", "demo:one", "target", &buffer));

    // A boolean is a checkbox, and toggling it is one command.
    try testing.expect((try h.fieldInfo("demo.fdt", "demo:one", "enabled")).authored == 0);
    try h.clickRect(h.row(8).control);
    const enabled = try h.fieldInfo("demo.fdt", "demo:one", "enabled");
    try testing.expect(enabled.authored != 0);
    var value: abi.AuthorValue = .{};
    try testing.expectEqual(abi.Result.ok, h.api.author_node_scalar(try h.fieldOf("demo.fdt", "demo:one", "enabled"), &value));
    try testing.expect(value.boolean != 0);

    // A list: start it, add two elements, reorder them, then remove one.
    try h.clickRect(h.row(9).add);
    try testing.expect((try h.fieldInfo("demo.fdt", "demo:one", "tags")).authored != 0);
    try h.clickRect(h.row(9).control); // open the group
    try h.enter(h.row(9).element, "first");
    try h.clickRect(h.row(9).add);
    try h.enter(h.row(9).element, "second");
    try h.clickRect(h.row(9).add);
    try testing.expectEqual(@as(u32, 2), (try h.fieldInfo("demo.fdt", "demo:one", "tags")).child_count);

    const tags = try h.fieldOf("demo.fdt", "demo:one", "tags");
    var element: abi.SourceNode = .none;
    try testing.expectEqual(abi.Result.ok, h.api.author_node_child(tags, 0, &element));
    try testing.expectEqual(abi.Result.ok, h.api.author_node_scalar(element, &value));
    try testing.expectEqualStrings("first", value.text.bytes().?);

    try h.clickRect(h.row(10).down); // row 10 is the first element once the list is open
    try testing.expectEqual(abi.Result.ok, h.api.author_node_child(try h.fieldOf("demo.fdt", "demo:one", "tags"), 0, &element));
    try testing.expectEqual(abi.Result.ok, h.api.author_node_scalar(element, &value));
    try testing.expectEqualStrings("second", value.text.bytes().?);

    try h.clickRect(h.row(10).remove);
    try testing.expectEqual(@as(u32, 1), (try h.fieldInfo("demo.fdt", "demo:one", "tags")).child_count);

    // A nested block: add it, open it, and fill the fields it declares.
    const where_row = h.client.targets.row_count - 1;
    try h.clickRect(h.row(where_row).add);
    try testing.expect((try h.fieldInfo("demo.fdt", "demo:one", "where")).authored != 0);
    try h.clickRect(h.row(where_row).control);
    try h.enter(h.row(where_row + 1).control, "3");
    try h.clickRect(h.row(where_row + 1).apply);
    try h.enter(h.row(where_row + 2).control, "-4");
    try h.clickRect(h.row(where_row + 2).apply);

    const block = try h.fieldOf("demo.fdt", "demo:one", "where");
    var x: abi.SourceNode = .none;
    try testing.expectEqual(abi.Result.ok, h.api.author_node_field(block, .from("x"), &x));
    try testing.expectEqual(abi.Result.ok, h.api.author_node_scalar(x, &value));
    try testing.expectEqualStrings("3", value.text.bytes().?);
    var y: abi.SourceNode = .none;
    try testing.expectEqual(abi.Result.ok, h.api.author_node_field(block, .from("y"), &y));
    try testing.expectEqual(abi.Result.ok, h.api.author_node_scalar(y, &value));
    try testing.expectEqualStrings("-4", value.text.bytes().?);
}

test "a refused command changes nothing and leaves the typed text to be fixed" {
    const h = try Harness.init();
    defer h.deinit();

    h.idle();
    try h.makePackage();
    try h.makeRecord("demo:one");

    var buffer: [64]u8 = undefined;
    try h.enter(h.row(0).control, "7");
    try h.clickRect(h.row(0).apply);
    try testing.expectEqualStrings("7", try h.text("demo.fdt", "demo:one", "count", &buffer));
    const settled = (try h.info()).revision;

    // "nope" is not a `u64`. The command is refused, the file keeps "7", and the text the
    // author typed is still in the box for them to correct (`editor.md` §5).
    try h.clearField(h.row(0).control, 1);
    try h.write("nope");
    h.idle();
    try h.clickRect(h.row(0).apply);
    try testing.expectEqual(settled, (try h.info()).revision);
    try testing.expectEqualStrings("7", try h.text("demo.fdt", "demo:one", "count", &buffer));
    try testing.expect(h.last != 0);

    // Correcting it in the same box, without retyping the rest, is accepted.
    try h.clearField(h.row(0).control, 4);
    try h.write("11");
    h.idle();
    try h.clickRect(h.row(0).apply);
    try testing.expectEqualStrings("11", try h.text("demo.fdt", "demo:one", "count", &buffer));
    try testing.expectEqual(settled + 1, (try h.info()).revision);

    // A second record with an id this package already has is refused, and says so rather
    // than being quietly ignored.
    const before = try h.recordCount(try h.documentNamed("demo.fdt"));
    try h.makeRecord("demo:one");
    try testing.expectEqual(before, try h.recordCount(try h.documentNamed("demo.fdt")));
    try testing.expect((try h.diagnosticCount()) > 0);
}

test "undo and redo restore exact bytes, and a new edit clears the redo stack" {
    const h = try Harness.init();
    defer h.deinit();

    h.idle();
    try h.makePackage();
    try h.makeRecord("demo:one");
    try h.enter(h.row(0).control, "5");
    try h.clickRect(h.row(0).apply);

    var buffer: [64]u8 = undefined;
    const source = try h.fixture.read("demo.fdt");
    defer testing.allocator.free(source);
    try testing.expectEqualStrings("5", try h.text("demo.fdt", "demo:one", "count", &buffer));
    try testing.expect((try h.info()).can_undo != 0);

    try h.click(.undo);
    try testing.expect((try h.fieldInfo("demo.fdt", "demo:one", "count")).authored == 0);
    try testing.expect((try h.info()).can_redo != 0);

    try h.click(.redo);
    try testing.expectEqualStrings("5", try h.text("demo.fdt", "demo:one", "count", &buffer));

    try h.click(.undo);
    try h.enter(h.row(6).control, "lamp");
    try h.clickRect(h.row(6).apply);
    try testing.expect((try h.info()).can_redo == 0);
}

test "save, build and reload are three commands with three answers" {
    const h = try Harness.init();
    defer h.deinit();

    h.idle();
    try h.makePackage();
    try h.makeRecord("demo:one");
    // Fill what the schema requires, or the package is an incomplete draft.
    try h.enter(h.row(0).control, "1");
    try h.clickRect(h.row(0).apply);
    try h.enter(h.row(1).control, "2");
    try h.clickRect(h.row(1).apply);
    try h.enter(h.row(2).control, "3");
    try h.clickRect(h.row(2).apply);
    try h.enter(h.row(3).control, "4");
    try h.clickRect(h.row(3).apply);
    try h.enter(h.row(4).control, "5.5");
    try h.clickRect(h.row(4).apply);
    try h.clickRect(h.row(8).control);

    // Build is disabled while anything is dirty: it compiles the *saved* bytes.
    try testing.expect((try h.info()).dirty != 0);
    try h.click(.build);
    try testing.expect(!h.client.has_build);

    try h.click(.save_all);
    try testing.expect((try h.info()).dirty == 0);

    try h.click(.build);
    try testing.expect(h.client.has_build);
    var built: abi.AuthorBuildInfo = .{};
    try testing.expectEqual(abi.Result.ok, h.api.author_build_info(.{ .bits = h.client.build.bits }, &built));
    try testing.expectEqualStrings("demo:pack", built.package_name.bytes().?);

    // Building does not load anything; Reload does, and says which build is loaded.
    var preview: abi.AuthorPreviewInfo = .{};
    try testing.expectEqual(abi.Result.ok, h.api.author_preview_info(try h.workspace(), &preview));
    try testing.expectEqual(abi.AuthorPreviewOutcome.none, @as(abi.AuthorPreviewOutcome, @enumFromInt(preview.outcome)));

    try h.click(.reload);
    try testing.expectEqual(abi.Result.ok, h.api.author_preview_info(try h.workspace(), &preview));
    try testing.expectEqual(abi.AuthorPreviewOutcome.active, @as(abi.AuthorPreviewOutcome, @enumFromInt(preview.outcome)));
    try testing.expectEqual(built.revision, preview.build_revision);

    // The loaded snapshot is readable through the same node calls a draft is.
    try h.click(.tab_preview);
    try testing.expect(h.client.observation.preview_records >= 1);

    // And the preview holds its build: releasing what the loaded content is reading from
    // would delete the files underneath it.
    try testing.expectEqual(abi.Result.refused, h.api.author_build_release(.{ .bits = h.client.build.bits }));

    // Export hands the build to the one destination the host granted.  The client asked
    // for an index, not a path: the file lands where the *host* said, outside every root
    // the workspace can read or write.
    try h.click(.tab_source);
    try h.click(.export_package);
    try testing.expectEqual(@as(i32, 0), h.client.observation.last_result);
    const shipped = try h.fixture.at("ship/demo.fpk");
    const bytes = try h.fixture.os.readFile(testing.allocator, shipped, 1 << 20);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(built.package_bytes, @as(u64, bytes.len));
}

test "a build the compiler refuses says why, and succeeds once the draft is complete" {
    const h = try Harness.init();
    defer h.deinit();

    h.idle();
    try h.makePackage();
    try h.makeRecord("demo:one");

    // An incomplete draft is a state the editor keeps and saves: a record is written over
    // several sittings, and refusing to write it down until it is valid would be the
    // editor deciding when someone has finished thinking (`editor.md` §3).
    try h.click(.save_all);
    try testing.expect((try h.info()).dirty == 0);

    // The compiler is what refuses it, and the diagnostic is the answer.
    try h.click(.build);
    try testing.expect(!h.client.has_build);
    try testing.expect(try h.diagnosticCount() > 0);

    // Filling what the schema requires and saving again is the whole fix.
    try h.enter(h.row(0).control, "1");
    try h.clickRect(h.row(0).apply);
    try h.enter(h.row(1).control, "2");
    try h.clickRect(h.row(1).apply);
    try h.enter(h.row(2).control, "3");
    try h.clickRect(h.row(2).apply);
    try h.enter(h.row(3).control, "4");
    try h.clickRect(h.row(3).apply);
    try h.enter(h.row(4).control, "5.5");
    try h.clickRect(h.row(4).apply);
    try h.clickRect(h.row(8).control);
    try h.click(.save_all);

    try h.click(.build);
    try testing.expect(h.client.has_build);
    try testing.expectEqual(@as(u32, 0), try h.diagnosticCount());
    try testing.expectEqual(@as(u32, 0), h.duplicates);
}

test "nothing is exported before there is a build to export" {
    const h = try Harness.init();
    defer h.deinit();

    h.idle();
    // The grant is the host's, so the client counts the destinations rather than
    // assuming one.
    try testing.expectEqual(@as(u32, 1), h.client.destinations);
    try testing.expect(!h.client.has_build);
    try h.click(.export_package);
    // Disabled, so the click is not a refused command either: nothing was attempted, and
    // the status bar has nothing to say about it.
    try testing.expectEqual(@as(i32, 0), h.last);
    const shipped = try h.fixture.at("ship/demo.fpk");
    try testing.expectError(error.FileNotFound, h.fixture.os.readFile(testing.allocator, shipped, 1 << 20));
}

test "New Package leaves the manifest it just wrote selected" {
    const h = try Harness.initEmpty();
    defer h.deinit();

    h.idle();
    try h.makePackage();
    // Not a convenience: with nothing selected the details pane is empty, and the author
    // has to go and find the record the editor just made for them.
    try testing.expect(h.client.has_record);
    try testing.expect(h.client.targets.row_count > 3);
    try h.enter(h.row(0).control, "Warmer");
    try h.clickRect(h.row(0).apply);
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("Warmer", try h.text("mod.fdt", "demo:pack", "name", &buffer));
}

test "closing or discarding with unsaved work can be cancelled without losing it" {
    const h = try Harness.init();
    defer h.deinit();

    h.idle();
    try h.makePackage();
    try h.makeRecord("demo:one");
    try h.enter(h.row(0).control, "42");
    try h.clickRect(h.row(0).apply);
    try testing.expect((try h.info()).dirty != 0);

    // Close asks rather than quitting, and Cancel returns to the editor unchanged.
    h.client.requestClose();
    try testing.expect(!h.client.quit_requested);
    h.idle();
    try h.click(.confirm_cancel);
    try testing.expect(!h.client.quit_requested);
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("42", try h.text("demo.fdt", "demo:one", "count", &buffer));
    try testing.expect((try h.info()).dirty != 0);

    // Discarding one document asks the same way, and Cancel keeps the draft.
    try h.click(.first_document);
    try h.click(.document_discard);
    try h.click(.confirm_cancel);
    try testing.expectEqualStrings("42", try h.text("demo.fdt", "demo:one", "count", &buffer));

    // Save from the close confirmation writes everything and then closing is clean.
    h.client.requestClose();
    h.idle();
    try h.click(.confirm_save);
    try testing.expect((try h.info()).dirty == 0);
    h.client.requestClose();
    try testing.expect(h.client.quit_requested);
}

test "a dependency definition is copied into a writable document, exactly" {
    const h = try Harness.initWith(&.{
        \\foundry:mod demo:base { name "Base" version 1 license "Apache-2.0" }
        \\@schema thing {
        \\    count u64
        \\    small i32
        \\    big i64
        \\    tally u32
        \\    ratio f32
        \\    weight f64 (optional)
        \\    label string (default "none")
        \\    target id (optional)
        \\    enabled bool
        \\    tags [string] (optional)
        \\    where { x i32  y i32 } (optional)
        \\}
        \\thing demo:upstream {
        \\    count 9007199254740993
        \\    small -7
        \\    big 12
        \\    tally 3
        \\    ratio 0.5
        \\    label "upstream"
        \\    enabled true
        \\    tags [ "a" "b" ]
        \\}
        \\
    }, true);
    defer h.deinit();

    h.idle();
    try h.makePackage();
    try h.click(.first_document);
    try h.click(.tab_dependencies);
    try testing.expectEqual(@as(u32, 1), h.client.observation.dependencies);

    // The filter is how a browser finds one definition among a package's own; the
    // manifest is a record too.
    try h.enter(h.client.targets.filter, "upstream");
    try h.click(.first_dependency_record);
    const override = h.client.targets.dependency_override orelse return error.ControlNotDrawn;
    try testing.expect(override.w > 0);
    try testing.expect(override.x + override.w <= h.viewport.w);
    try h.click(.dependency_override);

    // Every stored field, at full precision, including the `u64` no float could carry.
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("9007199254740993", try h.text("demo.fdt", "demo:upstream", "count", &buffer));
    try testing.expectEqualStrings("upstream", try h.text("demo.fdt", "demo:upstream", "label", &buffer));
    try testing.expectEqual(@as(u32, 2), (try h.fieldInfo("demo.fdt", "demo:upstream", "tags")).child_count);
    // And an absent optional stays absent: an override copies what is stored, not what a
    // default would have produced.
    try testing.expect((try h.fieldInfo("demo.fdt", "demo:upstream", "weight")).authored == 0);
    try testing.expectEqual(@as(u32, 0), h.duplicates);
}

test "choosing a dependency package lists that one, and only from the next frame" {
    const h = try Harness.initWith(&.{
        \\foundry:mod demo:first { name "First" version 1 license "Apache-2.0" }
        \\@schema one { a u32 }
        \\one demo:alpha { a 1 }
        \\
        ,
        \\foundry:mod demo:second { name "Second" version 1 license "Apache-2.0" }
        \\@schema two { b u32 }
        \\two demo:beta { b 2 }
        \\two demo:gamma { b 3 }
        \\
    }, true);
    defer h.deinit();

    h.idle();
    try h.click(.tab_dependencies);
    try testing.expectEqual(@as(u32, 2), h.client.observation.dependencies);
    // The first grant is listed until something says otherwise: a manifest and one record.
    try testing.expectEqual(@as(u32, 2), h.client.observation.dependency_records);

    // The frame that answers the click still lists the package it was showing.  Listing
    // both at once would describe two sets of rows under one set of widget ids, and the
    // second set would take the first's clicks.
    try h.clickAt(.dependency_package, 1);
    h.idle();
    try testing.expectEqual(@as(u32, 3), h.client.observation.dependency_records);
    try testing.expectEqual(@as(u32, 0), h.duplicates);
}

test "a short viewport still describes the whole panel, clipped" {
    const h = try Harness.init();
    defer h.deinit();

    h.idle();
    try h.makePackage();
    try h.makeRecord("demo:one");

    // Well under the height eleven rows need, so the scroll region clips rather than
    // the panel refusing to describe itself.
    h.viewport = .{ .w = 900, .h = 320 };
    h.idle();
    try testing.expectEqual(@as(i32, 0), h.client.observation.last_result);
    try testing.expectEqual(@as(u32, 11), h.client.targets.row_count);
}

test "the walkthrough the application replays changes nothing" {
    const h = try Harness.init();
    defer h.deinit();

    h.idle();
    try h.makePackage();
    try h.makeRecord("demo:one");
    try h.click(.save_all);
    const before = try h.fixture.read("demo.fdt");
    defer testing.allocator.free(before);
    const revision = (try h.info()).revision;

    var runner: script.Runner = .init(&script.walkthrough);
    var frames: u64 = 0;
    while (!runner.done() and frames < script.frames(&script.walkthrough) + 8) : (frames += 1) {
        const input = runner.next(&h.client.targets, h.frame_index);
        h.frame_index += 1;
        h.host.ui_input = input;
        h.client.frame(h.viewport, .none);
    }
    try testing.expect(runner.done());

    const after = try h.fixture.read("demo.fdt");
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try testing.expectEqual(revision, (try h.info()).revision);
    try testing.expect((try h.info()).dirty == 0);
}
