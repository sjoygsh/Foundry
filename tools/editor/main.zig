//! Foundry's standalone content-record editor host (`docs/design/editor.md` §10).
//!
//! The host owns paths, grants, windows, rendering and preview publication.  Its client is a
//! separate module that receives only a pointer to `FoundryApi_v4`; no host value or private
//! handle crosses that seam.  M15 Step 6 is deliberately inspection-only.  The command/form
//! workflow is Step 7.

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
const render2d = @import("render2d");
const rhi = @import("rhi");
const ui = @import("ui");

pub const std_options = app.std_options;

const log = core.log.scoped(.editor);
const max_preview_package_bytes = 16 * 1024 * 1024;
const max_preview_total_bytes = 64 * 1024 * 1024;

const usage =
    \\foundry-editor — inspect a Foundry content workspace
    \\
    \\usage: foundry-editor --source <package-dir> --output <work-dir>
    \\                      [--dependency <file.fpk>] [--preview] [--frames <count>]
    \\
    \\  --source <dir>          host-granted package source root
    \\  --output <dir>          separate host-granted private candidate root
    \\  --dependency <file>     package granted to the workspace (repeatable, ordered)
    \\  --preview               build and activate once through FoundryApi_v4
    \\  --frames <count>        exit after a bounded number of frames; never saves
    \\  --help                  this text
    \\
;

const Args = struct {
    source: []const u8 = "",
    output: []const u8 = "",
    preview: bool = false,
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

    var preview: PreviewState = .init(gpa, os);
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
        .preview = .{ .ctx = &preview, .activate = PreviewState.activate },
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
    var client = try editor_client.Client.init(@ptrCast(@alignCast(public)));
    if (args.preview) {
        const result = client.requestPreview();
        if (result != 0) log.warn("preview activation returned {d}", .{result});
    }

    const frame_limit: ?u64 = if (args.frames) |limit| limit else if (platform.backend == .null) 3 else null;
    var typed: [32]platform.event.TextInput = undefined;
    while (!engine.shouldQuit()) {
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
        host.ui_input = .{
            .keys = engine.input,
            .pointer = engine.input.mouse.position,
            .wheel = engine.input.mouse.wheel,
            .text = typed[0..typed_len],
            .frame = engine.frame_index,
        };
        client.frame(.{ .x = 0, .y = 0, .w = width, .h = height });

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

/// One host-owned preview publication.  Candidate bytes are confined beneath the output
/// grant and loaded into fresh registry/store objects before the old publication is touched.
const PreviewState = struct {
    gpa: std.mem.Allocator,
    os: *platform.os.Os,
    active: ?*Loaded = null,
    generation: u64 = 0,

    fn init(gpa: std.mem.Allocator, os: *platform.os.Os) PreviewState {
        return .{ .gpa = gpa, .os = os };
    }

    fn deinit(self: *PreviewState) void {
        if (self.active) |loaded| loaded.destroy(self.gpa);
        self.* = undefined;
    }

    fn activate(ctx: ?*anyopaque, request: author.PreviewRequest) ?author.Publication {
        const self: *PreviewState = @ptrCast(@alignCast(ctx orelse return null));
        const next = Loaded.create(self.gpa, self.os, request) catch |err| {
            log.warn("preview candidate was refused ({t})", .{err});
            return null;
        };
        const previous = self.active;
        self.active = next;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        if (previous) |old| old.destroy(self.gpa);
        return .{
            .content_generation = self.generation,
            .store = &next.store,
            .registry = &next.registry,
        };
    }
};

const Loaded = struct {
    bytes: [][]u8,
    ids: []core.ContentId,
    registry: data.Registry,
    store: data.Store,

    fn create(
        gpa: std.mem.Allocator,
        os: *platform.os.Os,
        request: author.PreviewRequest,
    ) !*Loaded {
        const count: usize = @as(usize, request.dependency_count) + 1;
        const self = try gpa.create(Loaded);
        errdefer gpa.destroy(self);
        self.* = .{
            .bytes = try gpa.alloc([]u8, count),
            .ids = try gpa.alloc(core.ContentId, count),
            .registry = .init(gpa, .default),
            .store = .init(gpa, .default),
        };
        var read_count: usize = 0;
        errdefer {
            self.store.deinit(gpa);
            self.registry.deinit(gpa);
            for (self.bytes[0..read_count]) |bytes| gpa.free(bytes);
            gpa.free(self.ids);
            gpa.free(self.bytes);
        }

        var arena: core.Arena = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const candidates = try a.alloc(mod.Candidate, count);
        const enabled = try a.alloc(core.ContentId, count);
        const labels = try a.alloc([]const u8, count);
        var total: usize = 0;

        for (0..request.dependency_count) |index| {
            const path = try std.fmt.allocPrint(a, "{s}/dependencies/{d}/package.fpk", .{ request.candidate, index });
            try readCandidate(gpa, os, request.output_root, path, &self.bytes[index], &total);
            read_count += 1;
            var reader = try data.fpk.Reader.open(gpa, self.bytes[index], .default);
            defer reader.deinit();
            const manifest = try mod.manifest.read(a, &reader);
            self.ids[index] = manifest.id;
            enabled[index] = manifest.id;
            labels[index] = path;
            candidates[index] = .{
                .manifest = manifest,
                .base_dir = request.output_root,
                .file = path,
                .root = "",
                .origin = .installed,
            };
        }

        const own = count - 1;
        try readCandidate(gpa, os, request.output_root, request.package, &self.bytes[own], &total);
        read_count += 1;
        var own_reader = try data.fpk.Reader.open(gpa, self.bytes[own], .default);
        defer own_reader.deinit();
        const own_manifest = try mod.manifest.read(a, &own_reader);
        self.ids[own] = own_manifest.id;
        enabled[own] = own_manifest.id;
        labels[own] = request.package;
        candidates[own] = .{
            .manifest = own_manifest,
            .base_dir = request.output_root,
            .file = request.package,
            .root = request.assets,
            .origin = .installed,
        };

        var diagnostics: data.Diagnostics = .init(gpa, .default);
        defer diagnostics.deinit(gpa);
        var resolution = try mod.resolve(gpa, candidates, .{
            .enabled = enabled,
            .required = &.{own_manifest.id},
        }, &diagnostics);
        defer resolution.deinit();
        for (diagnostics.items.items) |entry| log.warn("preview: {s}", .{entry.message});

        for (resolution.order) |entry| {
            const at = for (self.ids, 0..) |candidate_id, index| {
                if (candidate_id.eql(entry.id)) break index;
            } else return error.ContentInvalid;
            _ = try self.store.add(gpa, labels[at], self.bytes[at], &self.registry, &diagnostics);
        }
        return self;
    }

    fn destroy(self: *Loaded, gpa: std.mem.Allocator) void {
        self.store.deinit(gpa);
        self.registry.deinit(gpa);
        for (self.bytes) |bytes| gpa.free(bytes);
        gpa.free(self.ids);
        gpa.free(self.bytes);
        gpa.destroy(self);
    }
};

fn readCandidate(
    gpa: std.mem.Allocator,
    os: *platform.os.Os,
    root: []const u8,
    relative: []const u8,
    out: *[]u8,
    total: *usize,
) !void {
    const read = try os.readFileConfined(gpa, root, relative, max_preview_package_bytes);
    errdefer gpa.free(read.bytes);
    total.* = std.math.add(usize, total.*, read.bytes.len) catch return error.OverBudget;
    if (total.* > max_preview_total_bytes) return error.OverBudget;
    out.* = read.bytes;
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
