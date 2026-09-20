//! Foundry's standalone content-record editor host (`docs/design/editor.md` §10).
//!
//! The host owns paths, grants, windows, rendering, keyboard shortcuts and preview
//! publication.  Its client is a separate module that receives only a pointer to
//! `FoundryApi_v4`; no host value or private handle crosses that seam.
//!
//! **Shortcuts are host input, not a Foundry capability.**  The public table publishes no
//! keyboard state — a native mod cannot read a key today — so a client cannot bind Ctrl+S
//! for itself.  The application reads its own keyboard and hands the client an intent, in
//! the same breath as the pointer snapshot it already supplies; every action that intent
//! starts is still an ordinary v4 call.  Publishing key state stays open (`editor.md` §13).

const std = @import("std");
const abi = @import("abi");
const app = @import("app");
const asset = @import("asset");
const author = @import("author");
const core = @import("core");
const data = @import("data");
const editor_client = @import("editor_client");
const mod = @import("mod");
const platform = @import("platform");
const preview_mod = @import("preview.zig");
const render2d = @import("render2d");
const rhi = @import("rhi");
const script = @import("script.zig");
const ui = @import("ui");

pub const std_options = app.std_options;

const log = core.log.scoped(.editor);

const usage =
    \\foundry-editor — inspect a Foundry content workspace
    \\
    \\usage: foundry-editor --source <package-dir> --output <work-dir>
    \\                      [--dependency <file.fpk>] [--preview] [--script]
    \\                      [--frames <count>]
    \\
    \\  --source <dir>          host-granted package source root
    \\  --output <dir>          separate host-granted private candidate root
    \\  --dependency <file>     package granted to the workspace (repeatable, ordered)
    \\  --preview               build and activate once through FoundryApi_v4
    \\  --script                replay the deterministic walkthrough, then exit
    \\  --frames <count>        exit after a bounded number of frames; never saves
    \\  --help                  this text
    \\
;

const Args = struct {
    source: []const u8 = "",
    output: []const u8 = "",
    preview: bool = false,
    script: bool = false,
    frames: ?u64 = null,
    dependencies: std.ArrayListUnmanaged(author.DependencySource) = .empty,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;

    var iterator = try init.minimal.args.iterateAllocator(gpa);
    defer iterator.deinit();
    _ = iterator.skip();
    var argv: std.ArrayList([]const u8) = .empty;
    defer {
        for (argv.items) |arg| gpa.free(arg);
        argv.deinit(gpa);
    }
    while (iterator.next()) |arg| try argv.append(gpa, try gpa.dupe(u8, arg));

    var stderr_buffer: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    defer stderr.interface.flush() catch {};

    var args = parseArgs(gpa, argv.items, &stderr.interface) catch |err| switch (err) {
        error.HelpRequested => {
            try stderr.interface.writeAll(usage);
            return 0;
        },
        error.BadUsage => {
            try stderr.interface.writeAll(usage);
            return 2;
        },
        else => return err,
    };
    defer args.dependencies.deinit(gpa);

    const env = try app.environment(gpa, init);
    defer gpa.free(env);
    var os = try platform.os.Os.init(gpa, .{ .env = env, .app_name = "foundry-editor" });
    defer os.deinit();

    os.createDirPath(args.output) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => {
            try stderr.interface.print("foundry-editor: cannot create output root '{s}': {s}\n", .{ args.output, @errorName(err) });
            return 1;
        },
    };

    run(gpa, env, os, args) catch |err| {
        try stderr.interface.print("foundry-editor: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(
    gpa: std.mem.Allocator,
    env: []const platform.os.EnvVar,
    os: *platform.os.Os,
    args: Args,
) !void {
    const content_dir = try app.contentDirOf(gpa, os, null);
    defer gpa.free(content_dir);
    const packages = [_]app.ContentPackage{
        .{ .file = "core.fpk", .root = "core" },
        .{ .file = "editor.fpk", .root = "editor" },
    };
    var engine = try app.Engine.init(gpa, .{
        .env = env,
        .app_name = "foundry-editor",
        .log_level = .info,
        .headless = platform.backend == .null,
        .window = .{
            .title = "Foundry Content Editor",
            .logical_width = 1440,
            .logical_height = 900,
            .surface = app.window_surface,
        },
        .content_dir = content_dir,
        .content = &packages,
    });
    defer engine.deinit();

    applyWindowIcon(gpa, engine);

    var renderer = try render2d.Renderer.init(gpa, engine.gpu, .{
        .frames_in_flight = 2,
        .jobs = engine.jobs(),
    });
    defer renderer.deinit();
    try engine.assets.registerLoader(gpa, render2d.textureLoader(&renderer));
    defer _ = engine.assets.unregisterLoader(gpa, asset.schemas.texture.id);

    const fallback_font: render2d.BitmapFont = .{
        .glyphs = .{ .texture = .none, .uv = .{}, .size_px = .{} },
        .cell = .{ .width = 8, .height = 8 },
        .columns = 16,
        .glyph_count = 95,
    };
    const fallback: app.UiFont = .{ .font = fallback_font };
    var context: ui.Context = .init(gpa, fallbackStyle(fallback));
    defer context.deinit();

    var preview: preview_mod.State = .init(gpa, os);
    defer preview.deinit();
    var service: author.Service = .init(gpa, os, .{});
    defer service.deinit();
    var diagnostics: data.Diagnostics = .init(gpa, .default);
    defer diagnostics.deinit(gpa);

    _ = service.open(args.source, .{
        .workspace = .{
            .dependencies = args.dependencies.items,
            .output_root = args.output,
            .grants = .{ .edit = true, .save = true, .build = true },
        },
        .preview = .{ .ctx = &preview, .activate = preview_mod.State.activate },
    }, &diagnostics) catch |err| {
        for (diagnostics.items.items) |entry| log.err("workspace: {s}", .{entry.message});
        return err;
    };
    for (diagnostics.items.items) |entry| log.warn("workspace: {s}", .{entry.message});

    var host: abi.Host = .{
        .engine = engine,
        .renderer = &renderer,
        .ui_context = &context,
        .author_service = &service,
    };
    host.bind();
    defer host.unbind();

    const public = abi.TableOf(abi.Host).getApi(abi.api_version_4) orelse return error.ApiUnavailable;
    // The client is large enough — sixty-eight screen strings, twenty-four field buffers —
    // that it belongs on the heap rather than in this frame.  The host owns its memory, as
    // it owns everything else the client is handed.
    const client = try gpa.create(editor_client.Client);
    defer gpa.destroy(client);
    client.* = try editor_client.Client.init(@ptrCast(@alignCast(public)));
    if (args.preview) {
        const result = client.requestPreview();
        if (result != 0) log.warn("preview activation returned {d}", .{result});
    }

    var replay: ?script.Runner = if (args.script) .init(&script.walkthrough) else null;
    const scripted_frames: ?u64 = if (args.script) script.frames(&script.walkthrough) else null;
    const frame_limit: ?u64 = args.frames orelse
        scripted_frames orelse
        (if (platform.backend == .null) @as(?u64, 3) else null);

    // What the UI actually captured while it ran, which is the part a frame count cannot
    // show: a windowed proof has to demonstrate that typing reached a field and that the
    // pointer was taken by a control rather than falling through (`editor.md` §12).
    var pointer_frames: u64 = 0;
    var keyboard_frames: u64 = 0;
    var peak_commands: usize = 0;

    var typed: [32]platform.event.TextInput = undefined;
    while (true) {
        // The window manager's close is the editor's Close command, not a shortcut past
        // it: unsaved work raises the in-window confirmation and the loop keeps running
        // until the author answers it (`editor.md` §6).
        if (engine.shouldQuit()) {
            client.requestClose();
            if (client.quit_requested) break;
            engine.quit = false;
        }
        if (client.quit_requested) break;
        engine.beginFrame();
        var typed_len: usize = 0;
        while (engine.nextEvent()) |event| switch (event) {
            .text_input => |text| if (typed_len < typed.len) {
                typed[typed_len] = text;
                typed_len += 1;
            },
            else => {},
        };

        const info = engine.windowInfo();
        const width: f32 = if (info) |window| @floatFromInt(window.logical_size.width) else 1440;
        const height: f32 = if (info) |window| @floatFromInt(window.logical_size.height) else 900;
        // A replay substitutes for the device entirely, so a scripted run is the same on
        // every machine and cannot be perturbed by a stray mouse.
        host.ui_input = if (replay) |*runner|
            runner.next(&client.targets, engine.frame_index)
        else
            .{
                .keys = engine.input,
                .pointer = engine.input.mouse.position,
                .wheel = engine.input.mouse.wheel,
                .text = typed[0..typed_len],
                .frame = engine.frame_index,
            };
        const shortcut: editor_client.Shortcut = if (replay != null) .none else shortcutOf(engine.input);
        client.frame(.{ .x = 0, .y = 0, .w = width, .h = height }, shortcut);

        if (context.wantsPointer()) pointer_frames += 1;
        if (context.wantsKeyboard()) keyboard_frames += 1;
        peak_commands = @max(peak_commands, context.list.commands.items.len);

        const scale: f32 = if (info) |window| window.scale else 1;
        try renderer.begin(.{
            .camera = .{ .viewport = .init(0, 0, width, height) },
            .pixel_scale = scale,
        });
        if (host.completedUiTheme()) |theme| {
            try app.drawUi(&context.list, &renderer, theme.font, .screen, theme.drawOptions(1));
        } else {
            try app.drawUi(&context.list, &renderer, fallback, .screen, .{ .layer = 1 });
        }

        engine.renderFrame(.{ .label = "editor", .clear = .{ 0.018, 0.020, 0.026, 1 } }, &renderer) catch |err| {
            if (!app.Engine.frameSkippable(err)) return err;
        };
        engine.endFrame();

        if (frame_limit) |limit| if (engine.frame_index >= limit) break;
        if (platform.backend == .null) engine.os.sleep(.fromMillis(1));
    }

    if (replay) |runner| log.info(
        "replayed {d} of {d} scripted actions in {d} frames; workspace {s}",
        .{
            runner.step,
            script.walkthrough.len,
            engine.frame_index,
            if (client.isDirty()) "has unsaved changes" else "is unchanged",
        },
    );
    log.info(
        "the interface held the pointer on {d} frame(s) and the keyboard on {d}, and drew up to {d} commands in one",
        .{ pointer_frames, keyboard_frames, peak_commands },
    );

    const seen = client.inspect();
    log.info(
        "inspected {d} workspace(s), {d} document(s), {d} source, {d} dependency and {d} preview record(s), {d} schema(s), {d} asset(s)",
        .{ seen.workspaces, seen.documents, seen.source_records, seen.dependency_records, seen.preview_records, seen.schemas, seen.assets },
    );
}

fn fallbackStyle(font: app.UiFont) ui.Style {
    return .{
        .font = font.metrics(),
        .text_scale = 1.5,
        .line_height = 22,
        .padding = .init(9, 4),
        .spacing = 4,
        .separator_thickness = 1,
        .text = .white,
        .text_dim = .{ .r = 0.5, .g = 0.5, .b = 0.55, .a = 1 },
        .surface = .{ .r = 0.02, .g = 0.025, .b = 0.035, .a = 1 },
        .control = .{ .r = 0.08, .g = 0.09, .b = 0.12, .a = 1 },
        .control_hot = .{ .r = 0.13, .g = 0.15, .b = 0.19, .a = 1 },
        .control_active = .{ .r = 0.2, .g = 0.23, .b = 0.29, .a = 1 },
        .accent = .{ .r = 0.05, .g = 0.28, .b = 0.62, .a = 1 },
    };
}

/// The editor's keyboard shortcuts, which are UE5's.
///
/// `super` on macOS is Command and Control elsewhere, and `platform` already reports that
/// distinction, so one table serves both without a target conditional.
fn shortcutOf(input: platform.InputSnapshot) editor_client.Shortcut {
    const modifier = if (comptime is_apple) input.modifiers.super else input.modifiers.ctrl;
    if (!modifier) return .none;
    if (input.wasPressed(.s)) return if (input.modifiers.shift) .save_all else .save;
    if (input.wasPressed(.z)) return if (input.modifiers.shift) .redo else .undo;
    if (input.wasPressed(.y)) return .redo;
    if (input.wasPressed(.b)) return .build;
    if (input.wasPressed(.r)) return .validate;
    if (input.wasPressed(.w)) return .close;
    return .none;
}

const is_apple = @import("builtin").target.os.tag.isDarwin();

fn applyWindowIcon(gpa: std.mem.Allocator, engine: *app.Engine) void {
    const bytes = @embedFile("content/icon.png");
    var image = asset.png.decode(gpa, bytes, .{ .max_dimension = platform.WindowIcon.max_dimension }) catch |err| {
        log.warn("window icon did not decode ({t})", .{err});
        return;
    };
    defer image.deinit(gpa);
    engine.setWindowIcon(.{
        .width = image.width,
        .height = image.height,
        .stride = @intCast(image.strideBytes()),
        .pixels = image.pixels,
    }) catch |err| log.warn("window icon was refused ({t})", .{err});
}

const ArgError = error{ HelpRequested, BadUsage } || std.Io.Writer.Error || std.mem.Allocator.Error;

fn parseArgs(gpa: std.mem.Allocator, argv: []const []const u8, writer: *std.Io.Writer) ArgError!Args {
    var args: Args = .{};
    errdefer args.dependencies.deinit(gpa);
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--help")) return error.HelpRequested;
        if (std.mem.eql(u8, arg, "--preview")) {
            args.preview = true;
        } else if (std.mem.eql(u8, arg, "--script")) {
            args.script = true;
        } else if (std.mem.eql(u8, arg, "--source")) {
            args.source = try take(argv, &index, arg, writer);
        } else if (std.mem.eql(u8, arg, "--output")) {
            args.output = try take(argv, &index, arg, writer);
        } else if (std.mem.eql(u8, arg, "--dependency")) {
            const path = try take(argv, &index, arg, writer);
            try args.dependencies.append(gpa, .{ .path = path });
        } else if (std.mem.eql(u8, arg, "--frames")) {
            const text = try take(argv, &index, arg, writer);
            args.frames = std.fmt.parseInt(u64, text, 10) catch {
                try writer.print("foundry-editor: '{s}' is not a frame count\n", .{text});
                return error.BadUsage;
            };
            if (args.frames.? == 0) return error.BadUsage;
        } else {
            try writer.print("foundry-editor: unknown argument '{s}'\n", .{arg});
            return error.BadUsage;
        }
    }
    if (args.source.len == 0 or args.output.len == 0) {
        try writer.writeAll("foundry-editor: --source and --output are required\n");
        return error.BadUsage;
    }
    return args;
}

fn take(argv: []const []const u8, index: *usize, option: []const u8, writer: *std.Io.Writer) ArgError![]const u8 {
    index.* += 1;
    if (index.* >= argv.len) {
        try writer.print("foundry-editor: {s} needs a value\n", .{option});
        return error.BadUsage;
    }
    return argv[index.*];
}

test "arguments name explicit roots and ordered dependencies" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var args = try parseArgs(std.testing.allocator, &.{
        "--source", "source", "--output", "work", "--dependency", "core.fpk", "--preview", "--frames", "7",
    }, &writer);
    defer args.dependencies.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("source", args.source);
    try std.testing.expectEqualStrings("work", args.output);
    try std.testing.expectEqualStrings("core.fpk", args.dependencies.items[0].path);
    try std.testing.expect(args.preview);
    try std.testing.expectEqual(@as(?u64, 7), args.frames);
}

test "source and output grants are required" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.BadUsage, parseArgs(std.testing.allocator, &.{ "--source", "only" }, &writer));
}

test {
    _ = preview_mod;
    _ = script;
}
