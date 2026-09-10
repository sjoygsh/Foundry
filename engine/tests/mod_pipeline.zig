//! A package on disk to native behaviour in a world, through the complete M7 lifecycle.
//!
//! The C library is built as a separate artifact against `foundry.h`. This test copies it
//! beside a compiled package, discovers and resolves that package, lets `app` merge its
//! content, then proves `abi` opens the image and its registered system runs.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const rhi = @import("rhi");
const scene = @import("scene");
const app = @import("app");
const mod = @import("mod");
const abi = @import("abi");
const options = @import("mod_pipeline_options");

const testing = std.testing;
const gpa = testing.allocator;
const TestEngine = app.EngineOf(platform.null_backend.Platform, rhi.null_backend.Device);
const TestHost = abi.HostOf(TestEngine);

const core_source =
    \\foundry:mod foundry:core {
    \\    name "Foundry Core"
    \\    version 1
    \\    license "Apache-2.0"
    \\}
;

const mod_source =
    \\foundry:mod pipeline:mod {
    \\    name "Pipeline Test"
    \\    version 1
    \\    license "Apache-2.0"
    \\    requires [ { id foundry:core } ]
    \\    abi { min 1  max 1 }
    \\    native "pipeline_mod"
    \\}
    \\@schema pipeline:counter { value u32 }
;

const tail_source =
    \\foundry:mod tail:mod {
    \\    name "Shutdown Tail"
    \\    version 1
    \\    license "Apache-2.0"
    \\    requires [ { id pipeline:mod } ]
    \\    abi { min 1  max 1 }
    \\    native "shutdown_mod"
    \\}
    \\@schema tail:marker { }
;

const refused_source =
    \\foundry:mod refused:mod {
    \\    name "Refused Native Test"
    \\    version 1
    \\    license "Apache-2.0"
    \\    requires [ { id foundry:core } ]
    \\    abi { min 1  max 1 }
    \\    native "callback_refused_mod"
    \\}
    \\@schema refused:survives { value u32 }
;

fn writePackage(
    os: *platform.Os,
    dir: []const u8,
    registry: *data.Registry,
    diags: *data.Diagnostics,
    name: []const u8,
    source: []const u8,
) !void {
    const colon = std.mem.indexOfScalar(u8, name, ':').?;
    var doc = try data.parser.parse(gpa, "mod.fdt", source, .{ .namespace = name[0..colon] }, diags);
    defer doc.deinit(gpa);

    var package = try data.check.Package.init(gpa, name, 1, .default);
    defer package.deinit(gpa);
    try package.addDocument(gpa, &doc, registry, diags);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try data.fpk.write(gpa, &package, registry, &bytes);

    const stem = name[0..colon];
    const file_name = try std.fmt.allocPrint(gpa, "{s}.fpk", .{stem});
    defer gpa.free(file_name);
    const path = try platform.os.joinPath(gpa, &.{ dir, file_name });
    defer gpa.free(path);
    try os.writeFile(path, bytes.items);
}

fn copyLibrary(os: *platform.Os, content_dir: []const u8, root: []const u8, native: []const u8, source: []const u8) !void {
    const package_root = try platform.os.joinPath(gpa, &.{ content_dir, root });
    defer gpa.free(package_root);
    try os.createDirPath(package_root);
    const name = try abi.libraryFileNameAlloc(gpa, native);
    defer gpa.free(name);
    const destination = try platform.os.joinPath(gpa, &.{ package_root, name });
    defer gpa.free(destination);
    const bytes = try os.readFile(gpa, source, 64 << 20);
    defer gpa.free(bytes);
    try os.writeFile(destination, bytes);
}

test "a discovered package loads native code, registers behaviour, and shuts down" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const content_dir = path_buf[0..path_len];

    var os = try platform.Os.init(gpa, .{ .app_name = "foundry-mod-pipeline", .env = &.{} });
    defer os.deinit();
    var registry: data.Registry = .init(gpa, .default);
    defer registry.deinit(gpa);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    try mod.schemas.registerAll(gpa, &registry);
    try writePackage(os, content_dir, &registry, &diags, "foundry:core", core_source);
    try writePackage(os, content_dir, &registry, &diags, "pipeline:mod", mod_source);
    try writePackage(os, content_dir, &registry, &diags, "tail:mod", tail_source);
    try writePackage(os, content_dir, &registry, &diags, "refused:mod", refused_source);
    try copyLibrary(os, content_dir, "pipeline", "pipeline_mod", options.native_mod_path);
    try copyLibrary(os, content_dir, "tail", "shutdown_mod", options.shutdown_mod_path);
    try copyLibrary(os, content_dir, "refused", "callback_refused_mod", options.callback_refused_mod_path);

    var discovery = try mod.discover(gpa, os, content_dir, .{}, &diags);
    defer discovery.deinit();
    var resolution = try mod.resolve(gpa, discovery.candidates, .{
        .required = &.{core.ContentId.fromString("foundry:core")},
        .enabled = &.{
            core.ContentId.fromString("pipeline:mod"),
            core.ContentId.fromString("tail:mod"),
            core.ContentId.fromString("refused:mod"),
        },
    }, &diags);
    defer resolution.deinit();
    try testing.expectEqual(@as(usize, 4), resolution.order.len);

    const packages = try gpa.alloc(app.ContentPackage, resolution.order.len);
    defer gpa.free(packages);
    for (resolution.order, packages) |entry, *package| {
        package.* = .{ .file = entry.file, .root = entry.root };
    }
    const engine = try TestEngine.init(gpa, .{
        .headless = true,
        .content_dir = content_dir,
        .content = packages,
        .log_capture = null,
    });
    defer engine.deinit();

    var world: scene.World = .init(gpa, &engine.schemas, .default);
    defer world.deinit();
    var host: TestHost = .{ .engine = engine, .world = &world };
    host.bind();
    defer host.unbind();
    var loader = abi.NativeLoaderOf(TestHost).init(gpa, &host);
    defer loader.deinit();

    try loader.load(content_dir, resolution.order, &diags);
    try testing.expectEqual(@as(usize, 3), loader.loaded.items.len);
    try testing.expect(engine.schemas.lookup(data.SchemaId.fromStringUnchecked("refused:survives")) != null);
    try testing.expectEqual(@as(u32, 2), world.componentTypeCount());
    // The refused registration remains in the world's append-only metadata, but its host
    // slot is neutralized and therefore cannot call back into the refusing image.
    try testing.expectEqual(@as(u32, 2), world.systemCount());

    const RefusedUpdateCount = *const fn () callconv(.c) u32;
    const refused_id = core.ContentId.fromString("refused:mod");
    const refused = for (loader.loaded.items) |*loaded| {
        if (loaded.id.eql(refused_id)) break loaded;
    } else unreachable;
    try testing.expect(host.modId(refused.self) == null);
    try testing.expect(refused.shutdown == null);
    const refused_update_count = refused.library.symbol(RefusedUpdateCount, "foundry_test_update_calls").?;

    world.update(.{ .tick = 7, .delta = .fromNanos(16_666_667) });
    try testing.expectEqual(@as(u32, 0), refused_update_count());
    try testing.expectEqual(@as(u32, 1), world.entityCount());
    const counter = world.findComponent(data.SchemaId.fromStringUnchecked("pipeline:counter")).?;
    var entities = world.liveEntities();
    const entity = entities.next().?;
    const bytes = world.getComponent(entity, counter).?;
    try testing.expectEqual(@as(u32, 42), std.mem.bytesAsValue(u32, bytes[0..@sizeOf(u32)]).*);

    loader.shutdown();
    try testing.expectEqual(@as(u32, 3), world.entityCount());
    const marker = world.findComponent(data.SchemaId.fromStringUnchecked("tail:marker")).?;
    var after_shutdown = world.liveEntities();
    _ = after_shutdown.next().?;
    const tail_entity = after_shutdown.next().?;
    const pipeline_entity = after_shutdown.next().?;
    try testing.expect(world.hasComponent(tail_entity, marker));
    try testing.expect(world.hasComponent(pipeline_entity, counter));
    loader.shutdown();
    try testing.expectEqual(@as(u32, 3), world.entityCount());
    try testing.expectEqual(@as(usize, 1), diags.count());
}

test "every native refusal is diagnosed and does not stop another library" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const content_dir = path_buf[0..path_len];

    var os = try platform.Os.init(gpa, .{ .app_name = "foundry-native-refusals", .env = &.{} });
    defer os.deinit();
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    try copyLibrary(os, content_dir, "no_init", "no_init_mod", options.no_init_mod_path);
    try copyLibrary(os, content_dir, "refused", "refused_mod", options.refused_mod_path);
    try copyLibrary(os, content_dir, "unknown", "unknown_mod", options.unknown_mod_path);
    try copyLibrary(os, content_dir, "no_shutdown", "no_shutdown_mod", options.no_shutdown_mod_path);
    const corrupt_root = try platform.os.joinPath(gpa, &.{ content_dir, "corrupt" });
    defer gpa.free(corrupt_root);
    try os.createDirPath(corrupt_root);
    const corrupt_name = try abi.libraryFileNameAlloc(gpa, "corrupt_mod");
    defer gpa.free(corrupt_name);
    const corrupt_path = try platform.os.joinPath(gpa, &.{ corrupt_root, corrupt_name });
    defer gpa.free(corrupt_path);
    try os.writeFile(corrupt_path, "not a dynamic library");

    var host: abi.Host = .{};
    host.bind();
    defer host.unbind();
    var loader = abi.NativeLoaderOf(abi.Host).init(gpa, &host);
    defer loader.deinit();
    const entries = [_]mod.Entry{
        .{ .id = core.ContentId.fromString("test:content"), .name = "test:content", .file = "", .root = "", .version = 1 },
        .{ .id = core.ContentId.fromString("test:path"), .name = "test:path", .file = "", .root = "safe", .version = 1, .abi = .{}, .native = "../escape" },
        .{ .id = core.ContentId.fromString("test:root"), .name = "test:root", .file = "", .root = "../escape", .version = 1, .abi = .{}, .native = "unused" },
        .{ .id = core.ContentId.fromString("test:noabi"), .name = "test:noabi", .file = "", .root = "safe", .version = 1, .native = "unused" },
        .{ .id = core.ContentId.fromString("test:mixed"), .name = "test:mixed", .file = "", .root = "refused", .version = 1, .abi = .{ .min = 1, .max = 2 }, .native = "refused_mod", .script = .{ .entry = core.ContentId.fromString("test:scripts.main"), .binding = 1 } },
        .{ .id = core.ContentId.fromString("test:future"), .name = "test:future", .file = "", .root = "safe", .version = 1, .abi = .{ .min = 2 }, .native = "unused" },
        .{ .id = core.ContentId.fromString("test:missing"), .name = "test:missing", .file = "", .root = "missing", .version = 1, .abi = .{}, .native = "absent" },
        .{ .id = core.ContentId.fromString("test:corrupt"), .name = "test:corrupt", .file = "", .root = "corrupt", .version = 1, .abi = .{}, .native = "corrupt_mod" },
        .{ .id = core.ContentId.fromString("test:noinit"), .name = "test:noinit", .file = "", .root = "no_init", .version = 1, .abi = .{}, .native = "no_init_mod" },
        .{ .id = core.ContentId.fromString("test:refused"), .name = "test:refused", .file = "", .root = "refused", .version = 1, .abi = .{}, .native = "refused_mod" },
        .{ .id = core.ContentId.fromString("test:unknown"), .name = "test:unknown", .file = "", .root = "unknown", .version = 1, .abi = .{}, .native = "unknown_mod" },
        .{ .id = core.ContentId.fromString("test:noshutdown"), .name = "test:noshutdown", .file = "", .root = "no_shutdown", .version = 1, .abi = .{}, .native = "no_shutdown_mod" },
    };
    try loader.load(content_dir, &entries, &diags);
    try testing.expectEqual(@as(usize, 3), loader.loaded.items.len);
    for (loader.loaded.items[0..2]) |*loaded| {
        try testing.expect(loaded.library.symbol(abi.ModShutdown, abi.shutdown_symbol) != null);
        try testing.expect(loaded.shutdown == null);
    }
    const without_shutdown = &loader.loaded.items[2];
    try testing.expect(without_shutdown.library.symbol(abi.ModShutdown, abi.shutdown_symbol) == null);
    try testing.expect(without_shutdown.shutdown == null);
    try testing.expectEqual(@as(usize, 10), diags.count());
}

test "the native identity limit closes a library that has not run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const content_dir = path_buf[0..path_len];

    var os = try platform.Os.init(gpa, .{ .app_name = "foundry-native-limit", .env = &.{} });
    defer os.deinit();
    try copyLibrary(os, content_dir, "refused", "refused_mod", options.refused_mod_path);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var host: abi.Host = .{};
    host.bind();
    defer host.unbind();
    for (0..64) |i| {
        const name = try std.fmt.allocPrint(gpa, "limit:mod{d}", .{i});
        defer gpa.free(name);
        _ = try host.issueMod(data.contentId(name) catch unreachable, name);
    }
    var loader = abi.NativeLoaderOf(abi.Host).init(gpa, &host);
    defer loader.deinit();
    const entry = [_]mod.Entry{.{
        .id = core.ContentId.fromString("test:limit"),
        .name = "test:limit",
        .file = "",
        .root = "refused",
        .version = 1,
        .abi = .{},
        .native = "refused_mod",
    }};
    try loader.load(content_dir, &entry, &diags);
    try testing.expectEqual(@as(usize, 0), loader.loaded.items.len);
    try testing.expectEqual(@as(usize, 1), diags.count());
}
