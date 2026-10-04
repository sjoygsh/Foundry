//! The ordinary compiled content-only mod changes a real game, not a synthetic record.
const std = @import("std");
const app = @import("app");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const options = @import("court_test_options");
const fixtures = @import("game_tests.zig");
const game = @import("game.zig");
const Settings = @import("settings.zig").Settings;
const Text = @import("text.zig").Text;
const play = @import("testdata/play.zig");
const t = std.testing;

test "court: noon overrides lighting, words, warden and beacon and completes with exact replay" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = t.allocator;
    var env = try fixtures.TestEnv.initWithNoon(gpa, true);
    defer env.deinit(gpa);
    const settings = try Settings.read(env.store.lookup(core.ContentId.fromString("court:config.main")).?);
    try t.expectEqual(@as(f32, 12), settings.lighting.exposure_ev100);
    try t.expectEqual(@as(f32, 60000), settings.lighting.lights[0].intensity);
    try t.expectEqualStrings("The Court at Noon", Text.read(&env.store).title);
    try t.expectEqual(@as(f32, 0.75), env.game.warden.?.settings.?.speed);
    var moved = false;
    for (env.game.beacons[0..env.game.beacon_count]) |b| if (b.id.eql(core.ContentId.fromString("court:beacon.open"))) {
        try t.expectEqual(@as(f32, 3.8), b.settings.position.x);
        moved = true;
    };
    try t.expect(moved);
    const rec = try gpa.create(fixtures.Recording);
    defer gpa.destroy(rec);
    for ([_]*const play.Script{ &play.win, &play.caught, &play.fell }) |script| {
        var fresh = try fixtures.TestEnv.initWithNoon(gpa, true);
        defer fresh.deinit(gpa);
        rec.* = .{};
        const driver = try rec.run(&fresh.game, script);
        try t.expect(driver.succeeded());
        var replay = try fixtures.TestEnv.initWithNoon(gpa, true);
        defer replay.deinit(gpa);
        for (rec.intents[0..rec.len], rec.hashes[0..rec.len]) |intent, expected| {
            try replay.game.step(intent, fixtures.dt);
            try t.expectEqual(expected, replay.game.hashTick());
        }
        try t.expectEqual(@as(u32, 0), fresh.game.events_dropped);
        if (script == &play.win) {
            try t.expectEqual(@as(u32, 2), rec.events.get(.won));
            try t.expectEqual(@as(u32, 6), rec.events.get(.beacon));
            try t.expectEqual(game.Phase.title, fresh.game.phase);
            var starts: [8]usize = undefined;
            const begun = rec.starts(&starts);
            try t.expectEqual(@as(usize, 2), begun.len);
            const first = try rec.worldHashes(gpa, begun[0], begun[1]);
            defer gpa.free(first);
            const second = try rec.worldHashes(gpa, begun[1], rec.len);
            defer gpa.free(second);
            try t.expectEqualSlices(u64, first, second);
        }
    }
}

test "court: installed plus user discovery enables noon only by explicit selection" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = t.allocator;
    var scratch = t.tmpDir(.{});
    defer scratch.cleanup();
    const os = try platform.os.Os.init(gpa, .{});
    defer os.deinit();
    const io = t.io;
    try scratch.dir.createDirPath(io, "installed");
    try scratch.dir.createDirPath(io, "mods");
    for ([_]struct { source: []const u8, destination: []const u8 }{
        .{ .source = options.core_package, .destination = "installed/core.fpk" },
        .{ .source = options.package, .destination = "installed/court.fpk" },
        .{ .source = options.noon_package, .destination = "mods/noon.fpk" },
    }) |file| {
        const bytes = try os.readFile(gpa, file.source, 16 * 1024 * 1024);
        defer gpa.free(bytes);
        try scratch.dir.writeFile(io, .{ .sub_path = file.destination, .data = bytes });
    }
    const root = try scratch.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const installed = try platform.os.joinPath(gpa, &.{ root, "installed" });
    defer gpa.free(installed);
    const user = try platform.os.joinPath(gpa, &.{ root, "mods" });
    defer gpa.free(user);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    for ([_]bool{ false, true }) |enabled| {
        var mods = try app.ModSet.init(gpa, os, &.{
            .{ .dir = installed, .origin = .installed },
            .{ .dir = user, .origin = .user },
        }, .{ .required = &.{ core.ContentId.fromString("foundry:core"), core.ContentId.fromString("court:content") } }, &diags);
        defer mods.deinit();
        const noon = core.ContentId.fromString("noon:content");
        _ = try mods.start(if (enabled) &.{noon} else &.{}, &diags);
        const packages = try mods.contentPackages(gpa);
        defer gpa.free(packages);
        try t.expectEqual(@as(usize, if (enabled) 3 else 2), packages.len);
        if (enabled) {
            try t.expectEqualStrings("noon.fpk", packages[2].file);
            try t.expectEqualStrings(user, packages[2].base_dir.?);
        }
    }
}
