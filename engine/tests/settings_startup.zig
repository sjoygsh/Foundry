//! Starting up the way an application starts up: fallback, then content, then the player.
//!
//! `app.settings` is unit-tested where it lives, and every piece of this is proven there in
//! isolation. What is only testable here is the **order** — that a value comes out of a real
//! `.fpk` loaded by a real engine, that a saved preference outranks it, that reloading the
//! package moves a default without moving a choice, and that two applications on one machine
//! cannot read each other's file. Those are `distribution.md` §4's startup order and §12's
//! Defaults row, and none of them exists inside a single module.
//!
//! The user directory is a real one: the environment handed to `Os` points `HOME`,
//! `XDG_DATA_HOME` and `APPDATA` at a temporary directory, so `userDataDirAlloc` derives
//! exactly what it would on a player's machine and derives it somewhere disposable.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const rhi = @import("rhi");
const app = @import("app");

const testing = std.testing;
const gpa = testing.allocator;

const TestEngine = app.EngineOf(platform.null_backend.Platform, rhi.null_backend.Device);

/// What an application's package says about how the application presents itself. Ordinary
/// content, an ordinary schema, no privileged path (I3).
const package_source =
    \\@schema config {
    \\    window_width  u32 (default 1280)
    \\    window_height u32 (default 720)
    \\    master_volume f32 (default 1)
    \\}
    \\
    \\config demo:config.main {
    \\    window_width  1024
    \\    window_height 768
    \\    master_volume 0.5
    \\}
;

/// The same package after a mod changed both numbers. Nothing else about it moves.
const changed_source =
    \\@schema config {
    \\    window_width  u32 (default 1280)
    \\    window_height u32 (default 720)
    \\    master_volume f32 (default 1)
    \\}
    \\
    \\config demo:config.main {
    \\    window_width  800
    \\    window_height 600
    \\    master_volume 0.25
    \\}
;

const user_override_source =
    \\@schema demo:config {
    \\    window_width  u32 (default 1280)
    \\    window_height u32 (default 720)
    \\    master_volume f32 (default 1)
    \\}
    \\
    \\demo:config demo:config.main {
    \\    window_width  900
    \\    window_height 700
    \\    master_volume 0.75
    \\}
;

const changed_user_override_source =
    \\@schema demo:config {
    \\    window_width  u32 (default 1280)
    \\    window_height u32 (default 720)
    \\    master_volume f32 (default 1)
    \\}
    \\
    \\demo:config demo:config.main {
    \\    window_width  901
    \\    window_height 701
    \\    master_volume 0.25
    \\}
;

/// The application's own settings schema. Declared in code, not in content: preferences are
/// not a content package and are not merged into the store (ADR-0031).
const prefs_schema: data.Schema = .{
    .id = data.SchemaId.parse("demo:preferences") catch unreachable,
    .version = 1,
    .fields = &.{
        .{ .name = "window_width", .type = .u32, .presence = .optional },
        .{ .name = "window_height", .type = .u32, .presence = .optional },
        .{ .name = "master_volume", .type = .f32, .presence = .optional },
        .{ .name = "enabled", .type = .{ .list = &.string }, .presence = .optional },
    },
};

const record_id = "demo:config.main";
const app_name = "foundry-settings-startup";

/// One application's startup: its content on disk, its engine, and the directory its
/// preferences live in.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    root_len: usize = 0,
    env: [3]platform.os.EnvVar = undefined,
    os: *platform.Os = undefined,
    engine: *TestEngine = undefined,

    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.root_len = try self.tmp.dir.realPath(testing.io, &self.path_buf);
        const base = self.path_buf[0..self.root_len];

        // Every variable `userDataDirAlloc` consults, all pointing at the same disposable
        // place, so this test derives a user directory the same way a player's machine does
        // whichever platform it runs on.
        self.env = .{
            .{ .name = "HOME", .value = base },
            .{ .name = "XDG_DATA_HOME", .value = base },
            .{ .name = "APPDATA", .value = base },
        };
        self.os = try platform.Os.init(gpa, .{ .env = &self.env, .app_name = app_name });
        errdefer self.os.deinit();

        try writePackage(self.os, base, "demo:content", package_source);
        self.engine = try TestEngine.init(gpa, .{
            .headless = true,
            .content_dir = base,
            .content = &.{.{ .file = "demo.fpk", .root = "." }},
            .hot_reload = true,
            .log_capture = null,
        });
    }

    fn deinit(self: *Fixture) void {
        self.engine.deinit();
        self.os.deinit();
        self.tmp.cleanup();
    }

    fn root(self: *Fixture) []const u8 {
        return self.path_buf[0..self.root_len];
    }

    fn openFile(self: *Fixture) !app.settings.File {
        return app.settings.File.open(gpa, self.os, prefs_schema, .{});
    }
};

/// The three values an application resolves at startup, and where each came from.
const Presentation = struct {
    width: app.settings.Resolved(u32),
    height: app.settings.Resolved(u32),
    volume: app.settings.Resolved(f32),
};

/// §4 step 4, as the samples do it: fallback, then the package's record, then the file.
fn resolve(engine: *TestEngine, file: app.settings.File, keep: ?Presentation) Presentation {
    const record = engine.store.lookup(core.ContentId.fromString(record_id));
    const content: ?app.settings.Layer = if (record) |r|
        .{ .schema = r.schema, .fields = r.fields, .origin = .content }
    else
        null;
    const layers = [_]?app.settings.Layer{ content, file.layer(prefs_schema) };

    var out: Presentation = .{
        .width = app.settings.resolveInt(u32, "window_width", 1280, 320, 8192, &layers),
        .height = app.settings.resolveInt(u32, "window_height", 720, 320, 8192, &layers),
        .volume = app.settings.resolveFloat(f32, "master_volume", 1, 0, 1, &layers),
    };
    // The reload rule: a field the player already chose in this session is not re-resolved.
    if (keep) |previous| {
        if (previous.width.isUser()) out.width = previous.width;
        if (previous.height.isUser()) out.height = previous.height;
        if (previous.volume.isUser()) out.volume = previous.volume;
    }
    return out;
}

test "an application starts on its package's own defaults" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    var file = try fx.openFile();
    defer file.deinit(gpa);
    try testing.expectEqual(app.settings.State.absent, file.state());

    const at_start = resolve(fx.engine, file, null);
    try testing.expectEqual(@as(u32, 1024), at_start.width.value);
    try testing.expectEqual(app.settings.Origin.content, at_start.width.origin);
    try testing.expectEqual(@as(u32, 768), at_start.height.value);
    try testing.expectEqual(@as(f32, 0.5), at_start.volume.value);
    try testing.expectEqual(app.settings.Origin.content, at_start.volume.origin);
}

test "a user package keeps its own root through load and the content watcher" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const installed_dir = path_buf[0..path_len];

    var os = try platform.Os.init(gpa, .{ .app_name = app_name, .env = &.{} });
    defer os.deinit();
    const user_mods_dir = try platform.os.joinPath(gpa, &.{ installed_dir, "User Móds" });
    defer gpa.free(user_mods_dir);
    try os.createDirPath(user_mods_dir);
    try writePackage(os, installed_dir, "demo:content", package_source);
    try writePackage(os, user_mods_dir, "user:override", user_override_source);

    const engine = try TestEngine.init(gpa, .{
        .headless = true,
        .content_dir = installed_dir,
        .content = &.{
            .{ .file = "demo.fpk", .root = "." },
            .{ .base_dir = user_mods_dir, .file = "user.fpk", .root = "." },
        },
        .hot_reload = true,
        .hot_reload_frames = 1,
        .log_capture = null,
    });
    defer engine.deinit();

    try testing.expectEqual(@as(?i128, 900), contentInt(engine, "window_width"));
    const user_mount = engine.assets.rootOf(engine.store.loadOrder()[1]).?;
    try testing.expect(std.mem.startsWith(u8, user_mount, user_mods_dir));

    const before = engine.contentGeneration();
    try writePackage(os, user_mods_dir, "user:override", changed_user_override_source);
    engine.beginFrame();
    engine.endFrame();
    try testing.expect(engine.contentGeneration() != before);
    try testing.expectEqual(@as(?i128, 901), contentInt(engine, "window_width"));
    try testing.expect(std.mem.startsWith(
        u8,
        engine.assets.rootOf(engine.store.loadOrder()[1]).?,
        user_mods_dir,
    ));
}

test "a configured package cannot escape its host-supplied base" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const root = path_buf[0..path_len];

    try testing.expectError(error.ContentUnavailable, TestEngine.init(gpa, .{
        .headless = true,
        .content_dir = root,
        .content = &.{.{ .file = "../outside.fpk", .root = "." }},
        .log_capture = null,
    }));
    try testing.expectError(error.ContentUnavailable, TestEngine.init(gpa, .{
        .headless = true,
        .content_dir = root,
        .content = &.{.{ .file = "inside.fpk", .root = "../outside" }},
        .log_capture = null,
    }));
}

fn contentInt(engine: *TestEngine, field: []const u8) ?i128 {
    const record = engine.store.lookup(core.ContentId.fromString(record_id)) orelse return null;
    const index = record.schema.fieldIndex(field) orelse return null;
    return record.fields.intAt(index) catch null;
}

test "what the player saved outranks the package, and survives the process that saved it" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    {
        var file = try fx.openFile();
        defer file.deinit(gpa);

        // Only what the player chose is written. The height and the volume stay absent, so
        // the package that supplies them can still change them later.
        file.touch();
        file.flush(gpa, prefs_schema, &.{
            .{ .int = 1600 },
            null,
            null,
            .{ .list = &.{.{ .string = "brighter:content" }} },
        });
        try testing.expect(file.persist);
    }

    // A second `File` over the same directory, holding nothing from the first. This is the
    // question a relaunch asks, and the answer has to come off the disk.
    var reopened = try fx.openFile();
    defer reopened.deinit(gpa);
    try testing.expectEqual(app.settings.State.loaded, reopened.state());

    const now = resolve(fx.engine, reopened, null);
    try testing.expectEqual(@as(u32, 1600), now.width.value);
    try testing.expectEqual(app.settings.Origin.user, now.width.origin);
    try testing.expectEqual(@as(u32, 768), now.height.value);
    try testing.expectEqual(app.settings.Origin.content, now.height.origin);

    var selected = try app.settings.IdSet.read(gpa, reopened.layer(prefs_schema).?, "enabled", 64);
    defer selected.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), selected.ids.len);
    try testing.expectEqualStrings("brighter:content", selected.ids[0]);
}

test "a content change moves a default and leaves a choice where it is" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    var file = try fx.openFile();
    defer file.deinit(gpa);
    file.touch();
    file.flush(gpa, prefs_schema, &.{ .{ .int = 1600 }, null, null, null });

    var reopened = try fx.openFile();
    defer reopened.deinit(gpa);
    const before = resolve(fx.engine, reopened, null);
    try testing.expectEqual(@as(u32, 1600), before.width.value);
    try testing.expectEqual(@as(u32, 768), before.height.value);

    // An ordinary content reload — the same thing an author sees after saving a `.fdt` and
    // recompiling, and the same thing a newly installed mod does.
    try writePackage(fx.os, fx.root(), "demo:content", changed_source);
    fx.engine.reloadContent();

    const after = resolve(fx.engine, reopened, before);
    try testing.expectEqual(@as(u32, 1600), after.width.value);
    try testing.expectEqual(app.settings.Origin.user, after.width.origin);
    try testing.expectEqual(@as(u32, 600), after.height.value);
    try testing.expectEqual(app.settings.Origin.content, after.height.origin);
    try testing.expectEqual(@as(f32, 0.25), after.volume.value);
}

test "two applications on one machine keep their preferences apart" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    var mine = try fx.openFile();
    defer mine.deinit(gpa);
    mine.touch();
    mine.flush(gpa, prefs_schema, &.{ .{ .int = 1600 }, null, null, null });

    // A different application directory: the same machine, the same user, another game.
    const other_os = try platform.Os.init(gpa, .{ .env = &fx.env, .app_name = "foundry-other-sample" });
    defer other_os.deinit();
    var theirs = try app.settings.File.open(gpa, other_os, prefs_schema, .{});
    defer theirs.deinit(gpa);
    try testing.expectEqual(app.settings.State.absent, theirs.state());

    // And the stronger case: the same directory, another application's schema. The file is
    // recognisably not this build's, so it is kept rather than replaced, and writing is off
    // for the session — which is what stops an update from destroying a player's settings.
    var foreign_schema = prefs_schema;
    foreign_schema.id = data.SchemaId.parse("demo:other") catch unreachable;
    var confused = try app.settings.File.open(gpa, fx.os, foreign_schema, .{});
    defer confused.deinit(gpa);
    try testing.expectEqual(app.settings.State.preserved, confused.state());
    try testing.expect(!confused.persist);

    confused.touch();
    confused.flush(gpa, foreign_schema, &.{ .{ .int = 640 }, null, null, null });

    var still_mine = try fx.openFile();
    defer still_mine.deinit(gpa);
    try testing.expectEqual(app.settings.State.loaded, still_mine.state());
    try testing.expectEqual(@as(u32, 1600), resolve(fx.engine, still_mine, null).width.value);
}

test "a change is written once the changing stops" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    var file = try app.settings.File.open(gpa, fx.os, prefs_schema, .{ .settle_frames = 3 });
    defer file.deinit(gpa);

    const values = [_]?data.Value{ .{ .int = 1600 }, null, null, null };

    // A drag: every frame reports a change, and every frame restarts the wait. Ten frames
    // of movement write nothing at all.
    for (0..10) |_| {
        file.touch();
        file.tick(gpa, prefs_schema, &values);
        try testing.expect(file.dirty);
    }

    // The hand stops. The wait finishes on the third quiet frame, counting the one the last
    // movement already spent.
    file.tick(gpa, prefs_schema, &values);
    try testing.expect(file.dirty);
    file.tick(gpa, prefs_schema, &values);
    try testing.expect(!file.dirty);

    var reopened = try fx.openFile();
    defer reopened.deinit(gpa);
    try testing.expectEqual(app.settings.State.loaded, reopened.state());

    // And a run that may not write leaves nothing behind, however much it changes: a frame
    // budget marks a run nobody is watching (`distribution.md` §4).
    var scripted = try app.settings.File.open(gpa, fx.os, prefs_schema, .{ .persist = false, .settle_frames = 1 });
    defer scripted.deinit(gpa);
    scripted.touch();
    scripted.tick(gpa, prefs_schema, &[_]?data.Value{ .{ .int = 4000 }, null, null, null });

    var unchanged = try fx.openFile();
    defer unchanged.deinit(gpa);
    try testing.expectEqual(@as(u32, 1600), resolve(fx.engine, unchanged, null).width.value);
}

/// Compiles `source` into `<dir>/<namespace>.fpk`, the way `fpack` does at build time.
fn writePackage(os: *platform.Os, dir: []const u8, name: []const u8, source: []const u8) !void {
    var registry: data.Registry = .init(gpa, .default);
    defer registry.deinit(gpa);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);

    const colon = std.mem.indexOfScalar(u8, name, ':').?;
    var doc = try data.parser.parse(gpa, "demo.fdt", source, .{ .namespace = name[0..colon] }, &diags);
    defer doc.deinit(gpa);

    var package = try data.check.Package.init(gpa, name, 1, .default);
    defer package.deinit(gpa);
    try package.addDocument(gpa, &doc, &registry, &diags);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try data.fpk.write(gpa, &package, &registry, &bytes);

    const file_name = try std.fmt.allocPrint(gpa, "{s}.fpk", .{name[0..colon]});
    defer gpa.free(file_name);
    const path = try platform.os.joinPath(gpa, &.{ dir, file_name });
    defer gpa.free(path);
    try os.writeFile(path, bytes.items);
}
