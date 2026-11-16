//! The shipped environments' bytes, pinned (`docs/design/environment.md` §7.2 and §12, ADR-0083).
//!
//! Each of the yard's, the room's and the court's environments, and the `dusk` mod's evening
//! over the yard, is read from its package's own `environments.fdt`, compiled and decoded as content, its faces decoded from the PNGs the
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
    /// Below `dir`, for a package that is not a sample's own content.
    sub: []const u8 = "",
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
    .{ .dir = options.sandbox3d_content_dir, .namespace = "sandbox3d", .id = "sandbox3d:environments.day", .bytes_hash = 0xfd2510abb5d7d05b, .harmonics_hash = 0x3323b101cc30d51b },
    .{ .dir = options.sandbox3d_content_dir, .namespace = "sandbox3d", .id = "sandbox3d:environments.room", .faces = room_faces, .bytes_hash = 0x791b29c33b9f8dd, .harmonics_hash = 0xa78bf24dea1bd746 },
    .{ .dir = options.court_content_dir, .namespace = "court", .id = "court:environments.night", .bytes_hash = 0xc960faa26d6ae8c6, .harmonics_hash = 0x382ab0a4e7a68891 },
    // The `dusk` mod's override of the yard's day, by the same ID (`environment.md` §11).
    .{ .dir = options.sandbox3d_content_dir, .sub = "../testdata/mods/dusk", .namespace = "dusk", .id = "sandbox3d:environments.day", .bytes_hash = 0x92078d56937dbcbd, .harmonics_hash = 0x7b9b585eae809adf },
};
const day = 0;
const dusk = 3;

/// `textures/room/px.png` is `sandbox3d:textures.room.px`, as `fpack` derives it.
fn derivedId(gpa: Allocator, namespace: []const u8, path: []const u8) ![]u8 {
    const stem = path[0..std.mem.lastIndexOfScalar(u8, path, '.').?];
    const dotted = try gpa.dupe(u8, stem);
    defer gpa.free(dotted);
    std.mem.replaceScalar(u8, dotted, '/', '.');
    return std.fmt.allocPrint(gpa, "{s}:{s}", .{ namespace, dotted });
}

fn prefilterShipped(gpa: Allocator, os: *platform.os.Os, case: Shipped) !environment.Prefiltered {
    const path = try platform.os.joinPath(gpa, &.{ case.dir, case.sub, "environments.fdt" });
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
    // Every pin is checked before any fails, so a deliberate change prints all four.
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

/// Level 0's texel at the middle of the +Y face, the zenith, as linear RGB in cd/m².
fn zenith(out: environment.Prefiltered) [3]f32 {
    return out.texel(0, 2, out.size / 2, out.size / 2);
}

test "M41 the dusk mod's evening replaces the yard's day, seen in the zenith's texel" {
    const gpa = testing.allocator;
    const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-environments", .env = &.{} });
    defer os.deinit();
    var base = try prefilterShipped(gpa, os, shipped[day]);
    defer base.deinit(gpa);
    var evening = try prefilterShipped(gpa, os, shipped[dusk]);
    defer evening.deinit(gpa);
    // Each is its own record's zenith, colour times luminance, to an f16's precision: the day's
    // (0.25, 0.45, 1) at 40 cd/m², and dusk's (0.08, 0.12, 0.45) at 4.
    const want = [2][3]f32{ .{ 10, 18, 40 }, .{ 0.32, 0.48, 1.8 } };
    for ([_]environment.Prefiltered{ base, evening }, want) |out, expected| {
        const got = zenith(out);
        for (got, expected) |g, e| try testing.expectApproxEqRel(e, g, 0.01);
    }
}
