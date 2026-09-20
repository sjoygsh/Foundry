//! Authoring from outside, in C.
//!
//! `editor.md` §11 asks for a separate installed-header C consumer that performs the same
//! core operations as the editor, so that authoring is a public capability rather than a
//! privilege of the one Zig host that happens to ship with the engine. The consumer is
//! `fixtures/author_mod.c`: a C99 dynamic library compiled against `foundry.h` alone,
//! loaded through the ordinary native loader, and handed the same `FoundryApi_v4` a mod
//! gets. This test is the host it is loaded into — it grants the roots, opens the
//! workspace, and then reads the files the C code wrote.
//!
//! It lives here rather than beside `abi` because it needs three modules at once: the
//! authoring service, the native loader, and a real filesystem under both.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const mod = @import("mod");
const abi = @import("abi");
const author = @import("author");
const options = @import("mod_pipeline_options");

const testing = std.testing;
const gpa = testing.allocator;

fn copyLibrary(os: *platform.Os, root: []const u8, native: []const u8, source: []const u8) !void {
    try os.createDirPath(root);
    const name = try abi.libraryFileNameAlloc(gpa, native);
    defer gpa.free(name);
    const destination = try platform.os.joinPath(gpa, &.{ root, name });
    defer gpa.free(destination);
    const bytes = try os.readFile(gpa, source, 64 << 20);
    defer gpa.free(bytes);
    try os.writeFile(destination, bytes);
}

test "a C client writes, saves, compiles and exports a package through the public table" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const base = path_buf[0..path_len];

    var os = try platform.Os.init(gpa, .{ .app_name = "foundry-abi-authoring", .env = &.{} });
    defer os.deinit();

    const source_dir = try platform.os.joinPath(gpa, &.{ base, "src" });
    defer gpa.free(source_dir);
    const output_dir = try platform.os.joinPath(gpa, &.{ base, "out" });
    defer gpa.free(output_dir);
    const ship_dir = try platform.os.joinPath(gpa, &.{ base, "ship" });
    defer gpa.free(ship_dir);
    const library_dir = try platform.os.joinPath(gpa, &.{ base, "lib" });
    defer gpa.free(library_dir);
    try os.createDirPath(source_dir);
    try os.createDirPath(output_dir);
    try os.createDirPath(ship_dir);
    try copyLibrary(os, library_dir, "author_mod", options.author_mod_path);

    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);

    // An empty granted directory is where a new package starts (`editor.md` §4), and the
    // destination is the host's, exactly as it is for the editor: the C code asks for
    // destination zero and never spells a path.
    var service: author.Service = .init(gpa, os, .{});
    defer service.deinit();
    const destinations = [_]author.ExportTarget{.{
        .name = "test",
        .kind = .compiled,
        .package_root = ship_dir,
        .package_name = "cmod.fpk",
    }};
    _ = try service.open(source_dir, .{
        .workspace = .{
            .output_root = output_dir,
            .grants = .{ .edit = true, .save = true, .build = true },
        },
        .exports = &destinations,
    }, &diags);

    var host: abi.Host = .{ .author_service = &service };
    host.bind();
    defer host.unbind();

    var loader = abi.NativeLoaderOf(abi.Host).init(gpa, &host);
    defer loader.deinit();
    const entries = [_]mod.Entry{.{
        .id = core.ContentId.fromString("cmod:client"),
        .name = "cmod:client",
        .base_dir = base,
        .file = "",
        .root = "lib",
        .version = 1,
        .abi = .{ .min = 4, .max = 4 },
        .native = "author_mod",
    }};
    try loader.load(&entries, &diags);
    // The library stayed loaded, which means `foundry_mod_init` answered FOUNDRY_OK: a
    // refusal closes it and says so in a diagnostic instead.
    try testing.expectEqual(@as(usize, 1), loader.loaded.items.len);
    defer loader.shutdown();

    // The source the C client wrote, in the editor's own serializer.
    const manifest = try platform.os.joinPath(gpa, &.{ source_dir, "mod.fdt" });
    defer gpa.free(manifest);
    const written = try os.readFile(gpa, manifest, 1 << 20);
    defer gpa.free(written);
    try testing.expectEqualStrings(
        \\foundry:mod cmod:pack {
        \\    name "C Consumer"
        \\    version 2
        \\    license "Apache-2.0"
        \\}
        \\
    , written);

    // And the package it compiled and exported, which a game would install unchanged.
    const shipped = try platform.os.joinPath(gpa, &.{ ship_dir, "cmod.fpk" });
    defer gpa.free(shipped);
    const bytes = try os.readFile(gpa, shipped, 1 << 20);
    defer gpa.free(bytes);
    var reader = try data.fpk.Reader.open(gpa, bytes, .default);
    defer reader.deinit();
    try testing.expectEqualStrings("cmod:pack", reader.name);
    try testing.expectEqualStrings("cmod:pack", reader.record(0).?.name);
}

test "a C client handed no authoring service is refused rather than crashing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const base = path_buf[0..path_len];

    var os = try platform.Os.init(gpa, .{ .app_name = "foundry-abi-authoring-none", .env = &.{} });
    defer os.deinit();
    const library_dir = try platform.os.joinPath(gpa, &.{ base, "lib" });
    defer gpa.free(library_dir);
    try copyLibrary(os, library_dir, "author_mod", options.author_mod_path);

    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var host: abi.Host = .{};
    host.bind();
    defer host.unbind();

    var loader = abi.NativeLoaderOf(abi.Host).init(gpa, &host);
    defer loader.deinit();
    const entries = [_]mod.Entry{.{
        .id = core.ContentId.fromString("cmod:client"),
        .name = "cmod:client",
        .base_dir = base,
        .file = "",
        .root = "lib",
        .version = 1,
        .abi = .{ .min = 4, .max = 4 },
        .native = "author_mod",
    }};
    try loader.load(&entries, &diags);
    // The table's shape never varies within a version: the calls are there, they answer
    // `Unavailable`, and the client returns that code rather than faulting. The image
    // stays open so it can be closed in order, but its host slot is neutralized.
    try testing.expectEqual(@as(usize, 1), loader.loaded.items.len);
    defer loader.shutdown();
    try testing.expect(host.modId(loader.loaded.items[0].self) == null);
    try testing.expectEqual(@as(usize, 1), diags.count());
}
