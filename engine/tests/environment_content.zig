//! The shipped environments' bytes, pinned (`docs/design/environment.md` §7.2 and §12, ADR-0083).
//!
//! Each of the yard's, the room's and the court's environments is read from its sample's own
//! `environments.fdt`, compiled and decoded as content, its faces decoded from the PNGs the
//! package ships, and prefiltered. The cube's bytes and the harmonics are pinned by hash, so a
//! change to the prefilter, the records or the faces moves a pin on purpose, and a pin that
//! differs between macOS and Windows is ADR-0083's revisit trigger.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const asset = @import("asset");
const options = @import("mod_pipeline_options");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const environment = asset.environment;

const Shipped = struct {
    dir: []const u8,
    namespace: []const u8,
    id: []const u8,
    /// For a `faces` environment, its faces' files, in its order. The IDs a package derives
    /// from them are checked against the record's, so the two cannot drift apart.
    faces: ?[6][]const u8 = null,
    bytes_hash: u64,
    harmonics_hash: u64,
};

const room_faces = [6][]const u8{
    "textures/room/px.png", "textures/room/nx.png", "textures/room/py.png",
    "textures/room/ny.png", "textures/room/pz.png", "textures/room/nz.png",
};

const shipped = [_]Shipped{
    .{ .dir = options.sandbox3d_content_dir, .namespace = "sandbox3d", .id = "sandbox3d:environments.day", .bytes_hash = 0x1b6380a933adfaa0, .harmonics_hash = 0x14989442fc0e9cd3 },
    .{ .dir = options.sandbox3d_content_dir, .namespace = "sandbox3d", .id = "sandbox3d:environments.room", .faces = room_faces, .bytes_hash = 0x791b29c33b9f8dd, .harmonics_hash = 0xa78bf24dea1bd746 },
    .{ .dir = options.court_content_dir, .namespace = "court", .id = "court:environments.night", .bytes_hash = 0xc960faa26d6ae8c6, .harmonics_hash = 0x382ab0a4e7a68891 },
};

/// `textures/room/px.png` is `sandbox3d:textures.room.px`, as `fpack` derives it.
fn derivedId(gpa: Allocator, namespace: []const u8, path: []const u8) ![]u8 {
    const stem = path[0..std.mem.lastIndexOfScalar(u8, path, '.').?];
    const dotted = try gpa.dupe(u8, stem);
    defer gpa.free(dotted);
    std.mem.replaceScalar(u8, dotted, '/', '.');
    return std.fmt.allocPrint(gpa, "{s}:{s}", .{ namespace, dotted });
}

fn prefilterShipped(gpa: Allocator, os: *platform.os.Os, case: Shipped) !environment.Prefiltered {
    const path = try platform.os.joinPath(gpa, &.{ case.dir, "environments.fdt" });
    defer gpa.free(path);
    const text = try os.readFile(gpa, path, 1 << 20);
    defer gpa.free(text);

    var registry: data.Registry = .init(gpa, .default);
    defer registry.deinit(gpa);
    _ = try registry.register(gpa, environment.schema);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var doc = try data.parser.parse(gpa, "environments.fdt", text, .{ .namespace = case.namespace }, &diags);
    defer doc.deinit(gpa);
    var package = try data.check.Package.init(gpa, "t:content", 1, .default);
    defer package.deinit(gpa);
    try package.addDocument(gpa, &doc, &registry, &diags);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try data.fpk.write(gpa, &package, &registry, &bytes);
    var reader = try data.fpk.Reader.open(gpa, bytes.items, .default);
    defer reader.deinit();

    const want = core.ContentId.fromString(case.id);
    var i: u32 = 0;
    const env = while (reader.record(i)) |view| : (i += 1) {
        if (!view.id.eql(want)) continue;
        break try environment.decode(reader.fieldsOf(view, reader.schemaFor(view.schema_id).?.*));
    } else return error.TestUnexpectedResult;

    var images: [6]asset.Image = undefined;
    var faces: [6]environment.Face = undefined;
    var decoded: usize = 0;
    defer for (images[0..decoded]) |*image| image.deinit(gpa);
    if (case.faces) |files| {
        for (files, 0..) |file, k| {
            const derived = try derivedId(gpa, case.namespace, file);
            defer gpa.free(derived);
            try testing.expect(env.source.faces[k].eql(core.ContentId.fromString(derived)));
            const png_path = try platform.os.joinPath(gpa, &.{ case.dir, file });
            defer gpa.free(png_path);
            const png = try os.readFile(gpa, png_path, 1 << 20);
            defer gpa.free(png);
            images[k] = try asset.png.decode(gpa, png, .{ .max_dimension = 4096 });
            decoded += 1;
            faces[k] = .{ .image = images[k], .color_space = .srgb };
        }
    }
    return environment.prefilter(gpa, env, if (case.faces != null) &faces else &.{});
}

test "M41 the yard's, the room's and the court's environments prefilter to pinned bytes" {
    const gpa = testing.allocator;
    const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-environments", .env = &.{} });
    defer os.deinit();
    // Every pin is checked before any fails, so a deliberate change prints all three.
    var wrong: usize = 0;
    for (shipped) |case| {
        var out = try prefilterShipped(gpa, os, case);
        defer out.deinit(gpa);
        try testing.expectEqual(@as(u32, 128), out.size);
        try testing.expectEqual(@as(u32, 5), out.levels);
        const bytes_hash = core.id.fnv1a64(out.bytes);
        const harmonics_hash = core.id.fnv1a64(std.mem.asBytes(&out.harmonics));
        if (bytes_hash != case.bytes_hash or harmonics_hash != case.harmonics_hash) {
            std.debug.print("{s}: bytes 0x{x}, harmonics 0x{x}\n", .{ case.id, bytes_hash, harmonics_hash });
            wrong += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}
