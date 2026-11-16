//! M41's court under its night (`environment.md` §11): the night and the small fill beside it
//! light the court about as M40's ambient alone did, so the court stays as dark as it was.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const platform = @import("platform");
const Settings = @import("settings.zig").Settings;
const options = @import("court_test_options");
const testing = std.testing;

/// M40's ambient, the court's only indirect light before M41, in cd/m².
const m40_ambient = [3]f32{ 2, 3, 5 };

fn luminance(c: [3]f32) f32 {
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

test "court: the night and its fill light the paving and the walls as M40's ambient did, within a tenth" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const os = try platform.os.Os.init(gpa, .{});
    defer os.deinit();
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var schemas: data.Registry = .init(gpa, .default);
    defer schemas.deinit(gpa);
    try asset.schemas.registerAll(gpa, &schemas);
    var store: data.Store = .init(gpa, .default);
    defer store.deinit(gpa);
    const base = try os.readFile(gpa, options.core_package, 16 * 1024 * 1024);
    defer gpa.free(base);
    _ = try store.add(gpa, "foundry:core", base, &schemas, &diags);
    const bytes = try os.readFile(gpa, options.package, 16 * 1024 * 1024);
    defer gpa.free(bytes);
    _ = try store.add(gpa, "court:content", bytes, &schemas, &diags);

    const settings = try Settings.read(&store, store.lookup(core.ContentId.fromString("court:config.main")).?);
    try testing.expect(settings.environment.eql(core.ContentId.fromString("court:environments.night")));
    const record = store.lookup(settings.environment).?;
    try testing.expect(record.schema_id.eql(asset.environment.schema.id));
    var night = try asset.environment.prefilter(gpa, try asset.environment.decode(record.fields), &.{});
    defer night.deinit(gpa);

    const want = luminance(m40_ambient);
    // Facing up (the paving) and facing each way along the ground (the walls).
    for ([_][3]f32{ .{ 0, 1, 0 }, .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } }) |n| {
        const sky = asset.environment.evaluate(night.harmonics, n);
        var lit: [3]f32 = undefined;
        for (&lit, sky, settings.lighting.ambient) |*out, s, a| out.* = s + a;
        try testing.expectApproxEqRel(want, luminance(lit), 0.1);
    }
    // The fill is a fill: smaller than the night's own light facing up.
    try testing.expect(luminance(settings.lighting.ambient) < luminance(asset.environment.evaluate(night.harmonics, .{ 0, 1, 0 })));
}
