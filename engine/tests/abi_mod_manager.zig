//! The v3 table from a mod's side: mod management over a real set on disk, and a content
//! theme around whole UI frames.
//!
//! Integration tests because each crosses `abi`, `app` and what sits beneath them: the mod
//! set discovers compiled packages and writes real profile files, and a theme is resolved from
//! a loaded package through the real texture loader. Every call goes through the table that
//! `get_api(3)` hands out, as a C mod's would.

const std = @import("std");
const abi = @import("abi");
const app = @import("app");
const asset = @import("asset");
const core = @import("core");
const data = @import("data");
const mod = @import("mod");
const platform = @import("platform");
const render2d = @import("render2d");
const rhi = @import("rhi");
const ui = @import("ui");

const solidPng = @import("ui_theme.zig").solidPng;

const testing = std.testing;
const gpa = testing.allocator;

/// The selected device, as `abi_render_pipeline.zig` explains.
const Engine = app.EngineOf(platform.null_backend.Platform, rhi.Device);
const Host = abi.HostOf(Engine);
const Table = abi.TableOf(Host);

/// The table exactly as a native mod receives it.
fn api() *const abi.Api_v3 {
    return @ptrCast(@alignCast(Table.getApi(abi.api_version_3).?));
}

fn cid(name: []const u8) core.ContentId {
    return core.ContentId.fromString(name);
}

fn expectResult(expected: abi.Result, actual: abi.Result) !void {
    testing.expectEqual(expected, actual) catch |err| {
        std.debug.print("expected {s}, got {s}\n", .{ expected.name(), actual.name() });
        return err;
    };
}

// == Mod management ====================================================================

/// An installation and a player's `mods/` folder, filled with compiled packages, a mod set
/// over both with profiles on disk, and a host lending that set to the table.
const Mods = struct {
    tmp: testing.TmpDir,
    installed_dir: []u8,
    user_dir: []u8,
    data_dir: []u8,
    os: *platform.Os,
    diags: data.Diagnostics,
    set: app.ModSet,
    host: Host = .{},
    saves: Saves = .{},

    /// What the host's grant was asked to record.
    const Saves = struct {
        calls: u32 = 0,
        key: u32 = 0,
        fail: bool = false,

        fn record(ctx: ?*anyopaque, key: u32) bool {
            const self: *Saves = @ptrCast(@alignCast(ctx.?));
            if (self.fail) return false;
            self.calls += 1;
            self.key = key;
            return true;
        }
    };

    fn init() !*Mods {
        const self = try gpa.create(Mods);
        errdefer gpa.destroy(self);
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(testing.io, &path_buf);
        const base = path_buf[0..len];
        self.installed_dir = try platform.os.joinPath(gpa, &.{ base, "install" });
        errdefer gpa.free(self.installed_dir);
        self.user_dir = try platform.os.joinPath(gpa, &.{ base, "mods" });
        errdefer gpa.free(self.user_dir);
        self.data_dir = try platform.os.joinPath(gpa, &.{ base, "data" });
        errdefer gpa.free(self.data_dir);
        self.os = try platform.Os.init(gpa, .{ .app_name = "foundry-abi-mods", .env = &.{} });
        errdefer self.os.deinit();
        self.diags = .init(gpa, .default);
        errdefer self.diags.deinit(gpa);
        try self.os.createDirPath(self.installed_dir);
        try self.os.createDirPath(self.user_dir);
        try self.writeAll();

        const roots = [_]app.mods.Root{
            .{ .dir = self.installed_dir, .origin = .installed },
            .{ .dir = self.user_dir, .origin = .user },
        };
        self.set = try app.ModSet.init(gpa, self.os, &roots, .{
            .required = &.{ cid("foundry:core"), cid("game:content") },
        }, &self.diags);
        errdefer self.set.deinit();
        // The player's first run: no profile on disk, and a selection carried in from older
        // settings, one entry of which is no longer installed.
        try self.set.attachProfiles(try app.profiles.Store.open(gpa, self.os, self.data_dir, true), null, .{
            .name = "Default",
            .enabled = &.{ "night:content", "rug:content", "broken:content", "gone:content" },
        });
        // The developer override adds the installed lamps for this session alone.
        _ = try self.set.start(&.{cid("lamps:content")}, &self.diags);

        self.host = .{ .mod_set = &self.set };
        self.saves = .{};
        self.host.bind();
        return self;
    }

    fn deinit(self: *Mods) void {
        self.host.unbind();
        self.set.deinit();
        self.diags.deinit(gpa);
        self.os.deinit();
        gpa.free(self.data_dir);
        gpa.free(self.user_dir);
        gpa.free(self.installed_dir);
        self.tmp.cleanup();
        gpa.destroy(self);
    }

    fn grant(self: *Mods) void {
        self.host.mods_write = .{ .ctx = &self.saves, .save_active_profile = Saves.record };
    }

    fn writeAll(self: *Mods) !void {
        var registry: data.Registry = .init(gpa, .default);
        defer registry.deinit(gpa);
        try mod.schemas.registerAll(gpa, &registry);
        const packages = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
            .{
                self.installed_dir, "core.fpk", "foundry:core",
                \\foundry:mod foundry:core { name "Core" version 1 license "Apache-2.0" }
            },
            .{
                self.installed_dir, "game.fpk", "game:content",
                \\foundry:mod game:content { name "Game" version 1 license "Apache-2.0" requires [ { id foundry:core } ] }
                \\@schema game:thing { v u32 }
                \\game:thing game:lamp { v 1 }
                \\game:thing game:floor { v 2 }
            },
            .{
                self.installed_dir, "lamps.fpk", "lamps:content",
                \\foundry:mod lamps:content { name "Lamps" version 1 license "MIT" requires [ { id game:content } ] }
                \\game:thing game:lamp { v 10 }
            },
            // A player's copy of an installed package: skipped, the installed one loads.
            .{
                self.user_dir, "lamps.fpk", "lamps:content",
                \\foundry:mod lamps:content { name "Lamps, again" version 1 license "MIT" }
            },
            .{
                self.user_dir, "broken.fpk", "broken:content",
                \\foundry:mod broken:content { name "Broken" version 1 license "MIT" requires [ { id lamps:content  min 5 } ] }
            },
            .{
                self.user_dir, "nat.fpk", "nat:content",
                \\foundry:mod nat:content { name "Native" version 1 license "MIT" abi { min 3 } native "nat" }
            },
            .{
                self.user_dir, "night.fpk", "night:content",
                \\foundry:mod night:content { name "Night" version 1 license "CC0-1.0" requires [ { id game:content  min 1 } ] }
                \\game:thing game:lamp { v 20 }
                \\game:thing game:floor { v 21 }
            },
            .{
                self.user_dir, "rug.fpk", "rug:content",
                \\foundry:mod rug:content { name "Rug" version 1 license "MIT" requires [ { id game:content } ] }
                \\game:thing game:floor { v 30 }
            },
            .{
                self.user_dir, "twice-a.fpk", "twice:content",
                \\foundry:mod twice:content { name "Twice" version 1 license "MIT" }
            },
            .{
                self.user_dir, "twice-b.fpk", "twice:content",
                \\foundry:mod twice:content { name "Twice" version 1 license "MIT" }
            },
        };
        for (packages) |p| {
            const colon = std.mem.indexOfScalar(u8, p[2], ':').?;
            var doc = try data.parser.parse(gpa, "test.fdt", p[3], .{ .namespace = p[2][0..colon] }, &self.diags);
            defer doc.deinit(gpa);
            var package = try data.check.Package.init(gpa, p[2], 1, .default);
            defer package.deinit(gpa);
            try package.addDocument(gpa, &doc, &registry, &self.diags);
            var bytes: std.ArrayList(u8) = .empty;
            defer bytes.deinit(gpa);
            try data.fpk.write(gpa, &package, &registry, &bytes);
            const path = try platform.os.joinPath(gpa, &.{ p[0], p[1] });
            defer gpa.free(path);
            try self.os.writeFile(path, bytes.items);
        }
        try testing.expect(!self.diags.failed);
    }
};

/// Every installed copy, in the table's order.
fn installedAll(out: []abi.ModInfo) !usize {
    var cursor: abi.Cursor = .begin;
    var n: usize = 0;
    while (true) {
        var info: abi.ModInfo = .{};
        const result = api().mods_installed_next(&cursor, &info);
        if (result == .end) return n;
        try expectResult(.ok, result);
        out[n] = info;
        n += 1;
    }
}

fn findInfo(infos: []const abi.ModInfo, id_name: []const u8, origin: abi.ModOrigin) !abi.ModInfo {
    for (infos) |info| {
        if (std.mem.eql(u8, info.id_name.bytes().?, id_name) and info.origin == origin) return info;
    }
    return error.TestUnexpectedResult;
}

fn conflictsOf(package: []const u8, out: []abi.ModConflict) !usize {
    var cursor: abi.Cursor = .begin;
    var n: usize = 0;
    while (true) {
        var conflict: abi.ModConflict = .{};
        const result = api().mods_conflict_next(cid(package), &cursor, &conflict);
        if (result == .end) return n;
        try expectResult(.ok, result);
        out[n] = conflict;
        n += 1;
    }
}

test "a mod reads what is installed and chosen, and changes nothing without the host's grant" {
    const f = try Mods.init();
    defer f.deinit();
    const a = api();

    var infos: [16]abi.ModInfo = undefined;
    const n = try installedAll(&infos);
    const all = infos[0..n];
    // Each folder in the host's order, each sorted by file name, duplicates included.
    const order = [_][]const u8{
        "foundry:core", "game:content",  "lamps:content", "broken:content", "lamps:content",
        "nat:content",  "night:content", "rug:content",   "twice:content",  "twice:content",
    };
    try testing.expectEqual(order.len, n);
    for (all, order) |info, name| try testing.expectEqualStrings(name, info.id_name.bytes().?);

    const core_info = all[0];
    try testing.expectEqual(abi.mod_flag_required, core_info.flags);
    try testing.expectEqual(abi.ModOrigin.installed, core_info.origin);
    try testing.expectEqual(abi.mod_no_position, core_info.pending_index);
    try testing.expectEqual(@as(u32, 0), core_info.pending_position);
    try testing.expectEqual(@as(abi.Bool, 1), core_info.loaded);
    try testing.expectEqual(@as(abi.Bool, 1), core_info.pending_enabled);

    // The player's list is night, rug, broken, gone; the environment adds lamps after it.
    const night = try findInfo(all, "night:content", .user);
    try testing.expectEqualStrings("Night", night.name.bytes().?);
    try testing.expectEqualStrings("CC0-1.0", night.license.bytes().?);
    try testing.expectEqual(@as(u32, 0), night.pending_index);
    try testing.expectEqual(@as(u32, 2), night.pending_position);
    try testing.expectEqual(abi.ModSkipReason.none, night.skip_reason);
    try testing.expectEqual(@as(abi.Bool, 1), night.loaded);
    // Its lamp and floor override the game's, and lamps and rug later override both.
    try testing.expectEqual(@as(u32, 2), night.provides);
    try testing.expectEqual(@as(u32, 2), night.wins);
    try testing.expectEqual(@as(u32, 2), night.loses);

    const rug = try findInfo(all, "rug:content", .user);
    try testing.expectEqual(@as(u32, 1), rug.pending_index);
    try testing.expectEqual(@as(u32, 3), rug.pending_position);
    try testing.expectEqual(@as(u32, 1), rug.wins);
    try testing.expectEqual(@as(u32, 0), rug.loses);

    const broken = try findInfo(all, "broken:content", .user);
    try testing.expectEqual(@as(u32, 2), broken.pending_index);
    try testing.expectEqual(abi.mod_no_position, broken.pending_position);
    try testing.expectEqual(abi.ModSkipReason.dependency_version, broken.skip_reason);
    try testing.expect(broken.skip_other.eql(cid("lamps:content")));
    try testing.expectEqualStrings("lamps:content", broken.skip_other_name.bytes().?);
    try testing.expectEqual(@as(abi.Bool, 1), broken.pending_enabled);
    try testing.expectEqual(@as(abi.Bool, 0), broken.loaded);

    // Enabled by the environment, not the player: loaded, and in no profile.
    const lamps = try findInfo(all, "lamps:content", .installed);
    try testing.expectEqual(abi.mod_flag_environment, lamps.flags);
    try testing.expectEqual(abi.mod_no_position, lamps.pending_index);
    try testing.expectEqual(@as(u32, 4), lamps.pending_position);
    try testing.expectEqual(@as(abi.Bool, 0), lamps.pending_enabled);
    try testing.expectEqual(@as(abi.Bool, 1), lamps.loaded);
    const lamps_copy = try findInfo(all, "lamps:content", .user);
    try testing.expectEqual(abi.mod_flag_duplicate | abi.mod_flag_environment, lamps_copy.flags);
    try testing.expectEqual(abi.ModSkipReason.shadows_installed, lamps_copy.skip_reason);
    try testing.expectEqual(abi.mod_no_position, lamps_copy.pending_position);
    try testing.expectEqual(@as(abi.Bool, 0), lamps_copy.loaded);

    try testing.expectEqual(abi.ModSkipReason.duplicate, all[8].skip_reason);
    try testing.expectEqual(abi.ModSkipReason.duplicate, all[9].skip_reason);
    try testing.expectEqual(abi.mod_flag_duplicate, all[9].flags);

    const nat = try findInfo(all, "nat:content", .user);
    try testing.expectEqual(abi.mod_flag_native, nat.flags);
    try testing.expectEqualStrings("Native", nat.name.bytes().?);
    try testing.expectEqual(@as(abi.Bool, 0), nat.pending_enabled);
    try testing.expectEqual(abi.mod_no_position, nat.pending_position);

    // The player's list, uninstalled entry included, in the player's order.
    {
        var cursor: abi.Cursor = .begin;
        var pending: abi.ModPending = .{};
        const expected = [_]struct { []const u8, abi.Bool }{
            .{ "night:content", 1 }, .{ "rug:content", 1 }, .{ "broken:content", 1 }, .{ "gone:content", 0 },
        };
        for (expected) |e| {
            try expectResult(.ok, a.mods_pending_next(&cursor, &pending));
            try testing.expectEqualStrings(e[0], pending.name.bytes().?);
            try testing.expectEqual(e[1], pending.installed);
        }
        try expectResult(.end, a.mods_pending_next(&cursor, &pending));
    }

    // Dependencies, and whether the next start meets them.
    {
        var cursor: abi.Cursor = .begin;
        var requirement: abi.ModRequirement = .{};
        try expectResult(.ok, a.mods_requirement_next(cid("broken:content"), &cursor, &requirement));
        try testing.expectEqualStrings("lamps:content", requirement.name.bytes().?);
        try testing.expectEqual(@as(u32, 5), requirement.min_version);
        try testing.expectEqual(abi.mod_no_position, requirement.max_version);
        try testing.expectEqual(@as(abi.Bool, 0), requirement.satisfied);
        try expectResult(.end, a.mods_requirement_next(cid("broken:content"), &cursor, &requirement));

        cursor = .begin;
        try expectResult(.ok, a.mods_requirement_next(cid("night:content"), &cursor, &requirement));
        try testing.expect(requirement.id.eql(cid("game:content")));
        try testing.expectEqual(@as(abi.Bool, 1), requirement.satisfied);
        cursor = .begin;
        try expectResult(.not_found, a.mods_requirement_next(cid("gone:content"), &cursor, &requirement));
    }

    // Conflicts, sorted by record, and the provider chain of one.
    {
        var conflicts: [4]abi.ModConflict = undefined;
        try testing.expectEqual(@as(usize, 2), try conflictsOf("night:content", &conflicts));
        try testing.expectEqualStrings("game:floor", conflicts[0].name.bytes().?);
        try testing.expect(conflicts[0].winner.eql(cid("rug:content")));
        try testing.expectEqual(@as(u32, 3), conflicts[0].provider_count);
        try testing.expectEqualStrings("game:lamp", conflicts[1].name.bytes().?);
        try testing.expect(conflicts[1].winner.eql(cid("lamps:content")));
        try testing.expectEqual(@as(usize, 0), try conflictsOf("nat:content", &conflicts));

        var cursor: abi.Cursor = .begin;
        var provider: abi.ModProvider = .{};
        const chain = [_]struct { []const u8, u32 }{ .{ "game:content", 1 }, .{ "night:content", 2 }, .{ "lamps:content", 4 } };
        for (chain, 0..) |link, i| {
            try expectResult(.ok, a.mods_provider_next(cid("game:lamp"), &cursor, &provider));
            try testing.expect(provider.package.eql(cid(link[0])));
            try testing.expectEqual(link[1], provider.position);
            try testing.expectEqual(abi.boolOut(i == chain.len - 1), provider.winner);
        }
        try expectResult(.end, a.mods_provider_next(cid("game:lamp"), &cursor, &provider));
    }

    // One profile, fresh: named, saved and pending, and not yet on disk.
    {
        var cursor: abi.Cursor = .begin;
        var profile: abi.ModProfile = .{};
        try expectResult(.ok, a.mods_profile_next(&cursor, &profile));
        try testing.expectEqual(@as(u32, 1), profile.key);
        try testing.expectEqualStrings("Default", profile.name.bytes().?);
        try testing.expectEqual(@as(abi.Bool, 1), profile.saved);
        try testing.expectEqual(@as(abi.Bool, 1), profile.pending);
        try expectResult(.end, a.mods_profile_next(&cursor, &profile));
        var state: abi.ModProfileState = .{};
        try expectResult(.ok, a.mods_profile_active(&state));
        try testing.expectEqual(abi.ModProfileState{ .saved = 1, .pending = 1, .has_saved = 1, .has_pending = 1 }, state);
    }

    // No grant: every change is refused, and nothing moves, in memory or on disk.
    var key: u32 = 0;
    try expectResult(.refused, a.mods_set_enabled(cid("nat:content"), 1));
    try expectResult(.refused, a.mods_set_enabled(cid("night:content"), 0));
    try expectResult(.refused, a.mods_move(cid("rug:content"), 0));
    try expectResult(.refused, a.mods_revert());
    try expectResult(.refused, a.mods_apply());
    try expectResult(.refused, a.mods_profile_create(.from("New"), &key));
    try expectResult(.refused, a.mods_profile_copy(1, .from("Copy"), &key));
    try expectResult(.refused, a.mods_profile_rename(1, .from("Renamed")));
    try expectResult(.refused, a.mods_profile_delete(1));
    try expectResult(.refused, a.mods_profile_select(1));
    try testing.expectEqual(@as(u32, 0), key);
    try testing.expect(!f.set.changed());
    try testing.expect(f.set.savedIsFresh());
    try testing.expectEqual(@as(usize, 4), f.set.pending().len);
    var store = try app.profiles.Store.open(gpa, f.os, f.data_dir, false);
    defer store.deinit(gpa);
    var listing = try store.list(gpa);
    defer listing.deinit();
    try testing.expectEqual(@as(usize, 0), listing.entries.len);

    // Still refused as garbage before it is refused as ungranted.
    try expectResult(.invalid_argument, a.mods_set_enabled(.none, 1));
    try expectResult(.invalid_argument, a.mods_profile_create(.from(""), &key));
}

test "with the grant, a mod edits the pending selection and profiles, and walks it began are refused" {
    const f = try Mods.init();
    defer f.deinit();
    f.grant();
    const a = api();

    // A walk begun, then a change: the walk is over.
    var walk: abi.Cursor = .begin;
    var info: abi.ModInfo = .{};
    try expectResult(.ok, a.mods_installed_next(&walk, &info));
    try expectResult(.ok, a.mods_set_enabled(cid("nat:content"), 1));
    try expectResult(.invalid_argument, a.mods_installed_next(&walk, &info));

    var infos: [16]abi.ModInfo = undefined;
    var all = infos[0..try installedAll(&infos)];
    const nat = try findInfo(all, "nat:content", .user);
    try testing.expectEqual(@as(u32, 4), nat.pending_index);
    try testing.expectEqual(@as(u32, 4), nat.pending_position);
    try testing.expectEqual(@as(abi.Bool, 1), nat.pending_enabled);
    // Applied at the next start, never this one.
    try testing.expectEqual(@as(abi.Bool, 0), nat.loaded);

    // Rug to the top of the player's list: night's floor now beats it.
    try expectResult(.ok, a.mods_move(cid("rug:content"), 0));
    var conflicts: [4]abi.ModConflict = undefined;
    try testing.expectEqual(@as(usize, 1), try conflictsOf("rug:content", &conflicts));
    try testing.expect(conflicts[0].winner.eql(cid("night:content")));
    all = infos[0..try installedAll(&infos)];
    try testing.expectEqual(@as(u32, 0), (try findInfo(all, "rug:content", .user)).pending_index);
    try testing.expectEqual(@as(u32, 1), (try findInfo(all, "rug:content", .user)).loses);

    try expectResult(.refused, a.mods_set_enabled(cid("foundry:core"), 0));
    try expectResult(.not_found, a.mods_move(cid("twice:content"), 0));
    try expectResult(.not_found, a.mods_set_enabled(cid("never:spelled"), 1));
    var state: abi.ModProfileState = .{};
    try expectResult(.ok, a.mods_profile_active(&state));
    try testing.expectEqual(@as(abi.Bool, 1), state.changed);

    // Apply writes the profile in the player's order and asks the host to remember it.
    try expectResult(.ok, a.mods_apply());
    try testing.expectEqual(@as(u32, 1), f.saves.calls);
    try testing.expectEqual(@as(u32, 1), f.saves.key);
    try expectResult(.ok, a.mods_profile_active(&state));
    try testing.expectEqual(@as(abi.Bool, 0), state.changed);
    {
        var store = try app.profiles.Store.open(gpa, f.os, f.data_dir, false);
        defer store.deinit(gpa);
        var saved = try store.read(gpa, 1);
        defer saved.deinit();
        try testing.expectEqualStrings("Default", saved.contents.name);
        const expected = [_][]const u8{ "rug:content", "night:content", "broken:content", "gone:content", "nat:content" };
        try testing.expectEqual(expected.len, saved.contents.enabled.len);
        for (expected, saved.contents.enabled) |want, got| try testing.expectEqualStrings(want, got);
    }
    all = infos[0..try installedAll(&infos)];
    try testing.expectEqual(@as(abi.Bool, 0), (try findInfo(all, "nat:content", .user)).loaded);

    // Profiles.
    var created: u32 = 0;
    try expectResult(.ok, a.mods_profile_create(.from("Testing"), &created));
    try testing.expectEqual(@as(u32, 2), created);
    var copied: u32 = 0;
    try expectResult(.ok, a.mods_profile_copy(1, .from("Copy"), &copied));
    try testing.expectEqual(@as(u32, 3), copied);
    try expectResult(.ok, a.mods_profile_rename(2, .from("Renamed")));
    try expectResult(.invalid_argument, a.mods_profile_rename(2, .from("")));
    try expectResult(.invalid_argument, a.mods_profile_rename(2, .from("a\x01b")));
    try expectResult(.invalid_argument, a.mods_profile_rename(2, .from("x" ** 65)));
    try expectResult(.not_found, a.mods_profile_rename(9, .from("Nobody")));

    var profiles: abi.Cursor = .begin;
    var profile: abi.ModProfile = .{};
    try expectResult(.ok, a.mods_profile_next(&profiles, &profile));
    try expectResult(.ok, a.mods_profile_select(3));
    try expectResult(.invalid_argument, a.mods_profile_next(&profiles, &profile));
    try expectResult(.ok, a.mods_profile_active(&state));
    try testing.expectEqual(abi.ModProfileState{ .saved = 1, .pending = 3, .has_saved = 1, .has_pending = 1, .changed = 1 }, state);

    try expectResult(.refused, a.mods_profile_delete(3));
    try expectResult(.refused, a.mods_profile_delete(1));
    try expectResult(.ok, a.mods_profile_delete(2));
    try expectResult(.not_found, a.mods_profile_delete(2));
    try expectResult(.ok, a.mods_revert());
    try expectResult(.ok, a.mods_profile_active(&state));
    try testing.expectEqual(abi.ModProfileState{ .saved = 1, .pending = 1, .has_saved = 1, .has_pending = 1 }, state);

    profiles = .begin;
    const listed = [_]struct { u32, []const u8 }{ .{ 1, "Default" }, .{ 3, "Copy" } };
    for (listed) |l| {
        try expectResult(.ok, a.mods_profile_next(&profiles, &profile));
        try testing.expectEqual(l[0], profile.key);
        try testing.expectEqualStrings(l[1], profile.name.bytes().?);
    }
    try expectResult(.end, a.mods_profile_next(&profiles, &profile));

    // A host that cannot record the key says so; the profile itself was still written.
    try expectResult(.ok, a.mods_set_enabled(cid("nat:content"), 0));
    f.saves.fail = true;
    try expectResult(.internal, a.mods_apply());
    var store = try app.profiles.Store.open(gpa, f.os, f.data_dir, false);
    defer store.deinit(gpa);
    var saved = try store.read(gpa, 1);
    defer saved.deinit();
    try testing.expectEqual(@as(usize, 4), saved.contents.enabled.len);
}

test "a host that supplies no mod set answers unavailable" {
    var host: Host = .{};
    host.bind();
    defer host.unbind();
    var cursor: abi.Cursor = .begin;
    var info: abi.ModInfo = .{};
    try expectResult(.unavailable, api().mods_installed_next(&cursor, &info));
    try expectResult(.unavailable, api().mods_apply());
}

// == Themes ============================================================================

const theme_template =
    \\foundry:ui_theme {s} {{
    \\    atlas t:textures.atlas
    \\    font {{ texture t:textures.font  cell_w 8  cell_h 8  columns 16  count 95 }}
    \\    text_scale {s}
    \\    line_height {d}
    \\    padding_x 10
    \\    padding_y 8
    \\    spacing 5
    \\    patch_scale 2
    \\    colors {{ text 0xffe2b4f0  text_dim 0x96826ec8  surface 0x0a0806e1  control 0x2e261eeb
    \\             control_hot 0x4a3c2cf5  control_active 0x6e583cff  accent 0xffbe6eff
    \\             positive 0x7ccf7cff  negative 0xe06a5aff  warning 0xf0c050ff  selection 0xffbe6e60 }}
    \\    patches [ {{ part "panel"  x 0  y 0  w 12  h 12  left 4  top 4  right 4  bottom 4 }} ]
    \\    icons [ {{ name "lock"  x 0  y 16  w 8  h 8 }} ]
    \\}}
    \\
;

const base_style: ui.Style = .{
    .font = .{ .cell = .init(8, 8) },
    .line_height = 14,
    .padding = .init(4, 4),
    .spacing = 2,
    .text = .white,
    .text_dim = .white,
    .surface = .black,
    .control = .white,
    .control_hot = .white,
    .control_active = .white,
    .accent = .white,
};

/// An engine loading one package from disk, so a content reload is a real one; a renderer
/// with the texture loader; and a host lending both, with a UI context, to the table.
const Themes = struct {
    tmp: testing.TmpDir,
    dir: []u8,
    os: *platform.Os,
    engine: *Engine,
    renderer: render2d.Renderer,
    context: ui.Context,
    host: Host = .{},

    fn init() !*Themes {
        const self = try gpa.create(Themes);
        errdefer gpa.destroy(self);
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(testing.io, &path_buf);
        self.dir = try gpa.dupe(u8, path_buf[0..len]);
        errdefer gpa.free(self.dir);
        self.os = try platform.Os.init(gpa, .{ .app_name = "foundry-abi-themes", .env = &.{} });
        errdefer self.os.deinit();

        for ([_]struct { []const u8, u32, u32 }{ .{ "textures/atlas.png", 64, 32 }, .{ "textures/font.png", 128, 48 } }) |image| {
            const png = try solidPng(gpa, image[1], image[2]);
            defer gpa.free(png);
            const path = try platform.os.joinPath(gpa, &.{ self.dir, image[0] });
            defer gpa.free(path);
            try self.os.createDirPath(std.fs.path.dirname(path).?);
            try self.os.writeFile(path, png);
        }
        try self.writeContent(20);

        self.engine = try Engine.init(gpa, .{
            .headless = true,
            .hot_reload = false,
            .content_dir = self.dir,
            .content = &.{.{ .file = "t.fpk", .root = "." }},
            .log_capture = null,
        });
        errdefer self.engine.deinit();
        self.renderer = try render2d.Renderer.init(gpa, self.engine.gpu, .{ .quads_per_buffer = 64 });
        errdefer self.renderer.deinit();
        try self.engine.assets.registerLoader(gpa, render2d.textureLoader(&self.renderer));
        self.context = .init(gpa, base_style);
        self.host = .{ .engine = self.engine, .renderer = &self.renderer, .ui_context = &self.context, .ui_input = .{} };
        self.host.bind();
        return self;
    }

    fn deinit(self: *Themes) void {
        self.host.unbind();
        self.context.deinit();
        _ = self.engine.assets.unregisterLoader(gpa, asset.schemas.texture.id);
        self.renderer.deinit();
        self.engine.deinit();
        self.os.deinit();
        gpa.free(self.dir);
        self.tmp.cleanup();
        gpa.destroy(self);
    }

    /// The package: two textures, the theme at `line_height`, a broken theme, and sixteen
    /// more valid ones, so the host's sixteen slots can be filled and one more refused.
    fn writeContent(self: *Themes, line_height: u32) !void {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(gpa);
        try source.appendSlice(gpa,
            \\foundry:texture t:textures.atlas { source "textures/atlas.png" }
            \\foundry:texture t:textures.font  { source "textures/font.png" }
            \\
        );
        try source.print(gpa, theme_template, .{ "t:ui.theme", "1", line_height });
        try source.print(gpa, theme_template, .{ "t:ui.broken", "0", line_height });
        for (0..16) |i| {
            var name: [32]u8 = undefined;
            try source.print(gpa, theme_template, .{ try std.fmt.bufPrint(&name, "t:ui.extra{d}", .{i}), "1", line_height });
        }

        var registry: data.Registry = .init(gpa, .default);
        defer registry.deinit(gpa);
        try asset.schemas.registerAll(gpa, &registry);
        try asset.ui_theme.registerAll(gpa, &registry);
        var diags: data.Diagnostics = .init(gpa, .default);
        defer diags.deinit(gpa);
        var doc = try data.parser.parse(gpa, "t.fdt", source.items, .{ .namespace = "t" }, &diags);
        defer doc.deinit(gpa);
        var package = try data.check.Package.init(gpa, "t:content", 1, .default);
        defer package.deinit(gpa);
        try package.addDocument(gpa, &doc, &registry, &diags);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try data.fpk.write(gpa, &package, &registry, &bytes);
        const path = try platform.os.joinPath(gpa, &.{ self.dir, "t.fpk" });
        defer gpa.free(path);
        try self.os.writeFile(path, bytes.items);
    }

    fn atlasRefs(self: *Themes) u32 {
        const handle = self.engine.assets.find(cid("t:textures.atlas")) orelse return 0;
        return self.engine.assets.refCount(handle) orelse 0;
    }
};

const white: abi.UiColor = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
const viewport: abi.UiRect = .{ .w = 640, .h = 360 };

test "a theme resolved through the ABI skins whole frames, and a content reload retires it" {
    const f = try Themes.init();
    defer f.deinit();
    const a = api();

    var theme: abi.Theme = .none;
    try expectResult(.not_found, a.ui_theme_resolve(cid("t:ui.nowhere"), &theme));
    try expectResult(.refused, a.ui_theme_resolve(cid("t:textures.atlas"), &theme));
    try expectResult(.refused, a.ui_theme_resolve(cid("t:ui.broken"), &theme));
    try testing.expectEqual(@as(u32, 0), f.atlasRefs());
    try expectResult(.ok, a.ui_theme_resolve(cid("t:ui.theme"), &theme));
    try testing.expect(f.atlasRefs() > 0);
    var again: abi.Theme = .none;
    try expectResult(.ok, a.ui_theme_resolve(cid("t:ui.theme"), &again));
    try testing.expectEqual(theme, again);
    try expectResult(.refused, a.ui_theme_pop());

    // No theme around the frame: nothing to draw icons or images from.
    var found: abi.Bool = 9;
    try expectResult(.ok, a.ui_begin(&viewport));
    try expectResult(.refused, a.ui_icon(.from("lock"), .{ .x = 8, .y = 8 }, white, &found));
    try expectResult(.refused, a.ui_image(&.{ .w = 8, .h = 8 }, .{ .x = 8, .y = 8 }, white));
    try expectResult(.refused, a.ui_theme_push(theme));
    try expectResult(.refused, a.ui_theme_resolve(cid("t:ui.theme"), &again));
    try expectResult(.ok, a.ui_end());

    try expectResult(.ok, a.ui_theme_push(theme));
    try testing.expectEqual(@as(f32, 20), f.context.style.line_height);
    try testing.expect(f.context.skin != null);

    try expectResult(.ok, a.ui_begin(&viewport));
    try expectResult(.ok, a.ui_icon(.from("lock"), .{ .x = 8, .y = 8 }, white, &found));
    try testing.expectEqual(@as(abi.Bool, 1), found);
    try expectResult(.ok, a.ui_icon(.from("gauge"), .{ .x = 8, .y = 8 }, white, &found));
    try testing.expectEqual(@as(abi.Bool, 0), found);
    try expectResult(.ok, a.ui_image(&.{ .x = 0, .y = 16, .w = 8, .h = 8 }, .{ .x = 16, .y = 16 }, white));
    try expectResult(.invalid_argument, a.ui_image(&.{ .x = 60, .y = 0, .w = 8, .h = 8 }, .{ .x = 8, .y = 8 }, white));
    try expectResult(.refused, a.ui_theme_push(theme));
    try expectResult(.refused, a.ui_theme_pop());
    try expectResult(.ok, a.ui_end());

    // The host walks what the mod described with the theme the frame was drawn in: the icon
    // and the image both come from the theme's atlas.
    const used = f.host.completedUiTheme() orelse return error.TestUnexpectedResult;
    try f.renderer.begin(.{ .camera = .{ .viewport = .init(0, 0, 640, 360) } });
    try app.drawUi(&f.context.list, &f.renderer, used.font, .screen, used.drawOptions(0));
    var from_atlas: usize = 0;
    for (f.renderer.batcher.items.items) |item| {
        if (item.sprite.texture.eql(used.images[0])) from_atlas += 1;
    }
    try testing.expectEqual(@as(usize, 2), from_atlas);

    try expectResult(.ok, a.ui_theme_pop());
    try testing.expectEqual(@as(f32, 14), f.context.style.line_height);
    try testing.expect(f.context.skin == null);

    // Sixteen at once, and no more; the one refused holds nothing.
    for (0..15) |i| {
        var name: [32]u8 = undefined;
        var extra: abi.Theme = .none;
        try expectResult(.ok, a.ui_theme_resolve(cid(try std.fmt.bufPrint(&name, "t:ui.extra{d}", .{i})), &extra));
    }
    const full = f.atlasRefs();
    try testing.expectEqual(@as(u32, 16), full);
    var seventeenth: abi.Theme = .none;
    try expectResult(.limit, a.ui_theme_resolve(cid("t:ui.extra15"), &seventeenth));
    try testing.expectEqual(full, f.atlasRefs());
    // A theme already held is still answered from what the host holds.
    try expectResult(.ok, a.ui_theme_resolve(cid("t:ui.theme"), &again));
    try testing.expectEqual(theme, again);

    // A reload with the theme changed on disk. The pushed theme is dropped at the next
    // frame, its handle goes stale, and resolving again reads the new record.
    try expectResult(.ok, a.ui_theme_push(theme));
    const generation = f.engine.contentGeneration();
    try f.writeContent(30);
    f.engine.reloadContent();
    try testing.expect(f.engine.contentGeneration() != generation);
    try expectResult(.ok, a.ui_begin(&viewport));
    try testing.expectEqual(@as(f32, 14), f.context.style.line_height);
    try expectResult(.refused, a.ui_icon(.from("lock"), .{ .x = 8, .y = 8 }, white, &found));
    try expectResult(.ok, a.ui_end());
    try testing.expectEqual(@as(u32, 0), f.atlasRefs());
    try expectResult(.invalid_handle, a.ui_theme_push(theme));
    try expectResult(.refused, a.ui_theme_pop());

    var fresh: abi.Theme = .none;
    try expectResult(.ok, a.ui_theme_resolve(cid("t:ui.theme"), &fresh));
    try testing.expect(fresh.bits != theme.bits);
    try expectResult(.ok, a.ui_theme_push(fresh));
    try testing.expectEqual(@as(f32, 30), f.context.style.line_height);

    // Letting the host go releases everything it held and restores the context it was lent.
    f.host.unbind();
    try testing.expectEqual(@as(u32, 0), f.atlasRefs());
    try testing.expectEqual(@as(f32, 14), f.context.style.line_height);
    f.host.bind();
}
