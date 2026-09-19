//! The mod set: what is installed, what the player chose, in what order, and what that
//! order does to the content.
//!
//! **One object for every question** a mod screen, the public ABI and startup ask, so the
//! three can never disagree (`mod-management.md` §4). Beneath it is `mod`, which already
//! computes each answer from files alone; this is where a host's roots, its required
//! packages and a player's pending changes meet.
//!
//! **A changed selection applies at the next start** (ADR-0040). `start` resolves the
//! order this session loads, once, and nothing here changes it afterwards. What the player
//! edits is `pending`, whose resolution is `preview` and whose overrides are `conflicts`,
//! each cached until the selection changes again.
//!
//! **Origins are host authority.** The host says which root holds installed content and
//! which the player's own mods; a package cannot say it about itself (ADR-0031). The
//! duplicate rules that follow from it live in `mod.resolve`.
//!
//! Profiles on disk, the host's write grant and native consent arrive in later M14 steps;
//! until then the saved selection is whatever the host restores.
//!
//! Design: `docs/design/mod-management.md` §§4, 7 and 8.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const mod = @import("mod");
const platform = @import("platform");

const engine_mod = @import("engine.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Diagnostics = data.Diagnostics;
const Os = platform.os.Os;

const log = core.log.scoped(.mods);

pub const Origin = mod.Origin;

/// The directory under an application's user data where a player puts packages
/// (`distribution.md` §7). Players see it, so it is fixed.
pub const user_dir_name = "mods";

/// How many packages a selection may enable: a profile's bound (ADR-0040).
pub const max_enabled = 1024;

/// A directory the host grants for discovery, and whose it is.
pub const Root = struct {
    dir: []const u8,
    origin: Origin,
};

pub const Options = struct {
    /// Loaded always, first and in this order, and never part of a selection:
    /// `foundry:core` and the application's own package. A missing or skipped one is fatal.
    required: []const ContentId,
    /// Bounds on each package read. The origin is each root's.
    discover: mod.discover_mod.Options = .{},
};

/// One installed package, as discovery found it.
pub const Installed = struct {
    candidate: mod.Candidate,
    /// Host bootstrap: always loads and is never part of a selection.
    required: bool,
};

pub const Error = error{
    /// A required package is not a choice.
    Required,
    /// `move` names a package the pending selection does not enable.
    NotEnabled,
    /// More than `max_enabled` packages.
    SelectionFull,
} || Allocator.Error;

/// `<user data>/mods`, or null with a warning when this machine has no user-data location.
/// A missing directory is the ordinary first-run state, and discovery reports it as empty.
pub fn userRoot(gpa: Allocator, os: *Os) Allocator.Error!?[]u8 {
    const user_data = os.userDataDirAlloc(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.warn("user packages are unavailable ({t})", .{err});
            return null;
        },
    };
    defer gpa.free(user_data);
    return platform.os.joinPath(gpa, &.{ user_data, user_dir_name }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.warn("user packages are unavailable ({t})", .{err});
            return null;
        },
    };
}

pub const ModSet = struct {
    gpa: Allocator,
    /// Borrowed from the host, which outlives this: conflicts reread package tables.
    os: *Os,
    read_options: mod.discover_mod.Options,
    discoveries: []mod.Discovery = &.{},
    /// Every candidate of every root, in root order.
    candidates: []mod.Candidate = &.{},
    list: []Installed = &.{},
    required: []ContentId = &.{},

    /// The selection as last saved: what the next start uses if nothing changes.
    saved: std.ArrayList(ContentId) = .empty,
    /// The selection being edited, in the player's order.
    edited: std.ArrayList(ContentId) = .empty,
    /// This session's developer override: after the selection, and never saved.
    extra: std.ArrayList(ContentId) = .empty,

    session: ?mod.Resolution = null,
    preview_cache: ?mod.Resolution = null,
    conflicts_cache: ?mod.Conflicts = null,

    /// Discovers every root. A root that cannot be listed is a diagnostic and contributes
    /// nothing, as it always has for one.
    pub fn init(gpa: Allocator, os: *Os, roots: []const Root, options: Options, diags: *Diagnostics) Allocator.Error!ModSet {
        const required = try gpa.dupe(ContentId, options.required);
        errdefer gpa.free(required);

        var discoveries: std.ArrayList(mod.Discovery) = try .initCapacity(gpa, roots.len);
        errdefer {
            for (discoveries.items) |*d| d.deinit();
            discoveries.deinit(gpa);
        }
        var total: usize = 0;
        for (roots) |root| {
            var read = options.discover;
            read.origin = root.origin;
            discoveries.appendAssumeCapacity(try mod.discover(gpa, os, root.dir, read, diags));
            total += discoveries.items[discoveries.items.len - 1].candidates.len;
        }

        const candidates = try gpa.alloc(mod.Candidate, total);
        errdefer gpa.free(candidates);
        const list = try gpa.alloc(Installed, total);
        errdefer gpa.free(list);
        var at: usize = 0;
        for (discoveries.items) |d| {
            for (d.candidates) |c| {
                candidates[at] = c;
                list[at] = .{ .candidate = c, .required = contains(required, c.manifest.id) };
                at += 1;
            }
        }
        return .{
            .gpa = gpa,
            .os = os,
            .read_options = options.discover,
            .discoveries = try discoveries.toOwnedSlice(gpa),
            .candidates = candidates,
            .list = list,
            .required = required,
        };
    }

    pub fn deinit(self: *ModSet) void {
        const gpa = self.gpa;
        self.invalidate();
        if (self.session) |*s| s.deinit();
        self.extra.deinit(gpa);
        self.edited.deinit(gpa);
        self.saved.deinit(gpa);
        gpa.free(self.list);
        gpa.free(self.candidates);
        for (self.discoveries) |*d| d.deinit();
        gpa.free(self.discoveries);
        gpa.free(self.required);
        self.* = undefined;
    }

    /// Every package found in every root, duplicates included, with its origin.
    pub fn installed(self: *const ModSet) []const Installed {
        return self.list;
    }

    /// Sets the saved selection, and the pending one to it. The order is the player's:
    /// kept as given, first occurrence of a repeat winning, never sorted (ADR-0040).
    /// Required packages are dropped, since they are not a choice.
    pub fn restore(self: *ModSet, selection: []const ContentId) Error!void {
        self.saved.clearRetainingCapacity();
        for (selection) |id| {
            if (self.isRequired(id) or contains(self.saved.items, id)) continue;
            if (self.saved.items.len == max_enabled) return error.SelectionFull;
            try self.saved.append(self.gpa, id);
        }
        try self.revert();
    }

    /// Resolves the order this session loads: the saved selection, then `extra`, the
    /// developer override, which is never saved. Called once, before the engine exists.
    ///
    /// Errors are `mod.resolve`'s fatal ones: a required package missing or skipped, or two
    /// installed packages sharing an id.
    pub fn start(self: *ModSet, extra: []const ContentId, diags: *Diagnostics) mod.resolve_mod.Error!*const mod.Resolution {
        std.debug.assert(self.session == null);
        self.extra.clearRetainingCapacity();
        for (extra) |id| {
            if (self.isRequired(id) or contains(self.saved.items, id) or contains(self.extra.items, id)) continue;
            try self.extra.append(self.gpa, id);
        }
        self.invalidate();

        const request = try self.gpa.alloc(ContentId, self.saved.items.len + self.extra.items.len);
        defer self.gpa.free(request);
        @memcpy(request[0..self.saved.items.len], self.saved.items);
        @memcpy(request[self.saved.items.len..], self.extra.items);
        self.session = try mod.resolve(self.gpa, self.candidates, .{ .required = self.required, .enabled = request }, diags);
        return &self.session.?;
    }

    /// What this session loaded, once `start` has run.
    pub fn loaded(self: *const ModSet) ?*const mod.Resolution {
        return if (self.session) |*s| s else null;
    }

    /// The packages the environment enabled for this session alone.
    pub fn environment(self: *const ModSet) []const ContentId {
        return self.extra.items;
    }

    /// The selection the next start will use, in the player's order.
    pub fn pending(self: *const ModSet) []const ContentId {
        return self.edited.items;
    }

    /// Whether the pending selection differs from the saved one, order included.
    pub fn changed(self: *const ModSet) bool {
        if (self.saved.items.len != self.edited.items.len) return true;
        for (self.saved.items, self.edited.items) |a, b| if (!a.eql(b)) return true;
        return false;
    }

    pub fn isEnabled(self: *const ModSet, id: ContentId) bool {
        return contains(self.edited.items, id);
    }

    /// Enables a package at the end of the player's order, or disables it. Either is
    /// idempotent; neither affects this session (ADR-0040).
    pub fn setEnabled(self: *ModSet, id: ContentId, on: bool) Error!void {
        if (self.isRequired(id)) return error.Required;
        const at = indexOf(self.edited.items, id);
        if (on) {
            if (at != null) return;
            if (self.edited.items.len == max_enabled) return error.SelectionFull;
            try self.edited.append(self.gpa, id);
        } else {
            _ = self.edited.orderedRemove(at orelse return);
        }
        self.invalidate();
    }

    /// Moves an enabled package to `to` in the player's order, clamped to its end. Any
    /// position is accepted: the resolver keeps dependencies first, and `preview` shows
    /// where the package actually lands (`mod-management.md` §4).
    pub fn move(self: *ModSet, id: ContentId, to: u32) Error!void {
        const from = indexOf(self.edited.items, id) orelse return error.NotEnabled;
        const target = @min(to, self.edited.items.len - 1);
        if (target == from) return;
        _ = self.edited.orderedRemove(from);
        self.edited.insertAssumeCapacity(target, id);
        self.invalidate();
    }

    /// Discards every pending change.
    pub fn revert(self: *ModSet) Allocator.Error!void {
        self.edited.clearRetainingCapacity();
        try self.edited.appendSlice(self.gpa, self.saved.items);
        self.invalidate();
    }

    /// What the next start would load: the pending selection resolved, with this session's
    /// environment override, which the next start in the same environment applies too.
    ///
    /// Its diagnostics are discarded: they say again what its skips already carry, and
    /// `start` logged them once for the session.
    pub fn preview(self: *ModSet) mod.resolve_mod.Error!*const mod.Resolution {
        if (self.preview_cache) |*cached| return cached;
        var diags: Diagnostics = .init(self.gpa, .default);
        defer diags.deinit(self.gpa);

        const request = try self.gpa.alloc(ContentId, self.edited.items.len + self.extra.items.len);
        defer self.gpa.free(request);
        @memcpy(request[0..self.edited.items.len], self.edited.items);
        var n = self.edited.items.len;
        for (self.extra.items) |id| {
            if (contains(self.edited.items, id)) continue;
            request[n] = id;
            n += 1;
        }
        self.preview_cache = try mod.resolve(self.gpa, self.candidates, .{ .required = self.required, .enabled = request[0..n] }, &diags);
        return &self.preview_cache.?;
    }

    /// Who overrides whom in `preview`'s order, from each package's record table.
    pub fn conflicts(self: *ModSet) mod.resolve_mod.Error!*const mod.Conflicts {
        if (self.conflicts_cache) |*cached| return cached;
        const order = (try self.preview()).order;
        var diags: Diagnostics = .init(self.gpa, .default);
        defer diags.deinit(self.gpa);
        self.conflicts_cache = try mod.conflicts(self.gpa, self.os, order, self.read_options, &diags);
        // Rare, and not carried by the report beyond `readable`: a package gone or damaged
        // since discovery.
        for (diags.items.items) |d| log.warn("{s}", .{d.message});
        return &self.conflicts_cache.?;
    }

    /// This session's load order as `app.Config.content` takes it. The strings are
    /// borrowed from this set, which outlives the call to `Engine.init` that copies them;
    /// the caller frees the slice alone.
    pub fn contentPackages(self: *const ModSet, gpa: Allocator) Allocator.Error![]engine_mod.ContentPackage {
        const order = self.session.?.order;
        const out = try gpa.alloc(engine_mod.ContentPackage, order.len);
        for (out, order) |*p, entry| p.* = .{ .base_dir = entry.base_dir, .file = entry.file, .root = entry.root };
        return out;
    }

    fn isRequired(self: *const ModSet, id: ContentId) bool {
        return contains(self.required, id);
    }

    fn invalidate(self: *ModSet) void {
        if (self.conflicts_cache) |*c| c.deinit();
        self.conflicts_cache = null;
        if (self.preview_cache) |*p| p.deinit();
        self.preview_cache = null;
    }
};

fn indexOf(ids: []const ContentId, id: ContentId) ?usize {
    for (ids, 0..) |each, i| if (each.eql(id)) return i;
    return null;
}

fn contains(ids: []const ContentId, id: ContentId) bool {
    return indexOf(ids, id) != null;
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

fn cid(name: []const u8) ContentId {
    return ContentId.fromString(name);
}

/// Two roots on disk, an installation and a player's `mods/`, filled with compiled
/// packages.
const Fixture = struct {
    tmp: testing.TmpDir,
    installed_dir: []u8,
    user_dir: []u8,
    os: *Os,
    registry: data.Registry,
    diags: Diagnostics,

    fn init() !Fixture {
        const gpa = testing.allocator;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(testing.io, &path_buf);
        const installed_dir = try platform.os.joinPath(gpa, &.{ path_buf[0..len], "install" });
        errdefer gpa.free(installed_dir);
        const user_dir = try platform.os.joinPath(gpa, &.{ path_buf[0..len], "mods" });
        errdefer gpa.free(user_dir);
        const os = try Os.init(gpa, .{});
        errdefer os.deinit();
        try os.createDirPath(installed_dir);
        try os.createDirPath(user_dir);
        var registry: data.Registry = .init(gpa, .default);
        errdefer registry.deinit(gpa);
        try mod.schemas.registerAll(gpa, &registry);
        return .{
            .tmp = tmp,
            .installed_dir = installed_dir,
            .user_dir = user_dir,
            .os = os,
            .registry = registry,
            .diags = .init(gpa, .default),
        };
    }

    fn deinit(self: *Fixture) void {
        const gpa = testing.allocator;
        self.diags.deinit(gpa);
        self.registry.deinit(gpa);
        self.os.deinit();
        gpa.free(self.user_dir);
        gpa.free(self.installed_dir);
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, dir: []const u8, file: []const u8, name: []const u8, source: []const u8) !void {
        const gpa = testing.allocator;
        const colon = std.mem.indexOfScalar(u8, name, ':').?;
        var doc = try data.parser.parse(gpa, "test.fdt", source, .{ .namespace = name[0..colon] }, &self.diags);
        defer doc.deinit(gpa);
        var package = try data.check.Package.init(gpa, name, 1, .default);
        defer package.deinit(gpa);
        try package.addDocument(gpa, &doc, &self.registry, &self.diags);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try data.fpk.write(gpa, &package, &self.registry, &bytes);
        const path = try platform.os.joinPath(gpa, &.{ dir, file });
        defer gpa.free(path);
        try self.os.writeFile(path, bytes.items);
    }

    /// The game's two required packages installed with a mod of its own, and in `mods/`:
    /// a copy of that mod, two more mods, and one mod twice.
    fn standard(self: *Fixture) !void {
        try self.write(self.installed_dir, "core.fpk", "foundry:core",
            \\foundry:mod foundry:core { name "Core" version 1 license "MIT" }
        );
        try self.write(self.installed_dir, "game.fpk", "game:content",
            \\foundry:mod game:content { name "Game" version 1 license "MIT" requires [ { id foundry:core } ] }
            \\@schema game:thing { v u32 }
            \\game:thing game:lamp { v 1 }
            \\game:thing game:floor { v 2 }
        );
        try self.write(self.installed_dir, "lamps.fpk", "lamps:content",
            \\foundry:mod lamps:content { name "Lamps" version 1 license "MIT" requires [ { id game:content } ] }
            \\game:thing game:lamp { v 10 }
        );
        try self.write(self.user_dir, "lamps.fpk", "lamps:content",
            \\foundry:mod lamps:content { name "Lamps, again" version 1 license "MIT" }
        );
        try self.write(self.user_dir, "night.fpk", "night:content",
            \\foundry:mod night:content { name "Night" version 1 license "MIT" requires [ { id game:content } ] }
            \\game:thing game:lamp { v 20 }
            \\game:thing game:floor { v 21 }
        );
        try self.write(self.user_dir, "rug.fpk", "rug:content",
            \\foundry:mod rug:content { name "Rug" version 1 license "MIT" requires [ { id game:content } ] }
            \\game:thing game:floor { v 30 }
        );
        try self.write(self.user_dir, "twice.fpk", "twice:content",
            \\foundry:mod twice:content { name "Twice" version 1 license "MIT" }
        );
        try self.write(self.user_dir, "twice-copy.fpk", "twice:content",
            \\foundry:mod twice:content { name "Twice" version 1 license "MIT" }
        );
        try testing.expect(!self.diags.failed);
    }

    fn open(self: *Fixture, roots: []const Root) !ModSet {
        return ModSet.init(testing.allocator, self.os, roots, .{
            .required = &.{ cid("foundry:core"), cid("game:content") },
        }, &self.diags);
    }

    fn grants(self: *const Fixture) [2]Root {
        return .{
            .{ .dir = self.installed_dir, .origin = .installed },
            .{ .dir = self.user_dir, .origin = .user },
        };
    }
};

fn names(buf: [][]const u8, order: []const mod.Entry) [][]const u8 {
    for (order, 0..) |e, i| buf[i] = e.name;
    return buf[0..order.len];
}

test "two roots keep their origins, and a player's duplicates no longer stop the game" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();
    const roots = f.grants();
    var set = try f.open(&roots);
    defer set.deinit();

    try testing.expectEqual(@as(usize, 8), set.installed().len);
    var user: usize = 0;
    var required: usize = 0;
    for (set.installed()) |each| {
        if (each.candidate.origin == .user) user += 1;
        if (each.required) required += 1;
    }
    try testing.expectEqual(@as(usize, 5), user);
    try testing.expectEqual(@as(usize, 2), required);

    // A required package in a selection is dropped: it is not a choice.
    try set.restore(&.{ cid("night:content"), cid("game:content"), cid("lamps:content"), cid("night:content") });
    try testing.expectEqualDeep(@as([]const ContentId, &.{ cid("night:content"), cid("lamps:content") }), set.pending());

    const loaded = try set.start(&.{}, &f.diags);
    var buf: [8][]const u8 = undefined;
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "foundry:core", "game:content", "night:content", "lamps:content" }),
        names(&buf, loaded.order),
    );
    // The installed copy of `lamps` loads; the player's copy and both of `twice` do not,
    // and the game starts anyway.
    try testing.expectEqualStrings(f.installed_dir, loaded.order[3].base_dir);
    try testing.expectEqual(@as(usize, 3), loaded.skipped.len);
    try testing.expect(!f.diags.failed);

    const packages = try set.contentPackages(testing.allocator);
    defer testing.allocator.free(packages);
    try testing.expectEqual(@as(usize, 4), packages.len);
    try testing.expectEqualStrings("night.fpk", packages[2].file);
    try testing.expectEqualStrings(f.user_dir, packages[2].base_dir.?);
}

test "editing the selection changes the preview and the conflicts, never what loaded" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();
    const roots = f.grants();
    var set = try f.open(&roots);
    defer set.deinit();
    try set.restore(&.{cid("night:content")});
    _ = try set.start(&.{}, &f.diags);
    try testing.expect(!set.changed());

    var report = try set.conflicts();
    try testing.expectEqual(@as(usize, 2), report.contested.len);

    // `rug` enabled at the end wins the floor; moved to the front, `night` takes it back.
    try set.setEnabled(cid("rug:content"), true);
    try testing.expect(set.changed());
    var preview = try set.preview();
    var buf: [8][]const u8 = undefined;
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "foundry:core", "game:content", "night:content", "rug:content" }),
        names(&buf, preview.order),
    );
    report = try set.conflicts();
    const floor = report.providers(cid("game:floor"));
    try testing.expectEqualStrings("rug:content", preview.order[floor[floor.len - 1]].name);

    try set.move(cid("rug:content"), 0);
    preview = try set.preview();
    report = try set.conflicts();
    const floor_again = report.providers(cid("game:floor"));
    try testing.expectEqualStrings("night:content", preview.order[floor_again[floor_again.len - 1]].name);

    // Past the end is the end.
    try set.move(cid("rug:content"), 99);
    try testing.expectEqualDeep(@as([]const ContentId, &.{ cid("night:content"), cid("rug:content") }), set.pending());

    // What loaded is untouched by any of it.
    try testing.expectEqual(@as(usize, 3), set.loaded().?.order.len);

    try set.revert();
    try testing.expect(!set.changed());
    try testing.expectEqualDeep(@as([]const ContentId, &.{cid("night:content")}), set.pending());

    try testing.expectError(error.Required, set.setEnabled(cid("game:content"), false));
    try testing.expectError(error.NotEnabled, set.move(cid("rug:content"), 0));
    try set.setEnabled(cid("night:content"), false);
    try set.setEnabled(cid("night:content"), false);
    try testing.expectEqual(@as(usize, 0), set.pending().len);
}

test "the environment's packages load for this session, and are never part of the selection" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();
    const roots = f.grants();
    var set = try f.open(&roots);
    defer set.deinit();
    try set.restore(&.{cid("night:content")});

    const loaded = try set.start(&.{ cid("rug:content"), cid("night:content"), cid("foundry:core") }, &f.diags);
    try testing.expectEqual(@as(usize, 4), loaded.order.len);
    try testing.expectEqualDeep(@as([]const ContentId, &.{cid("rug:content")}), set.environment());
    try testing.expectEqualDeep(@as([]const ContentId, &.{cid("night:content")}), set.pending());
    // So the preview carries it too, and nothing reads as a pending change.
    try testing.expectEqual(@as(usize, 4), (try set.preview()).order.len);
    try testing.expect(!set.changed());
}

test "roots in either order give byte-identical previews and conflicts" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();

    const forward = f.grants();
    const backward = [_]Root{ forward[1], forward[0] };
    var reference: ?[]u8 = null;
    defer if (reference) |r| testing.allocator.free(r);
    for ([_][]const Root{ &forward, &backward }) |roots| {
        var set = try f.open(roots);
        defer set.deinit();
        try set.restore(&.{ cid("rug:content"), cid("twice:content"), cid("night:content"), cid("lamps:content") });
        _ = try set.start(&.{}, &f.diags);
        const text = try describe(&set);
        if (reference) |expected| {
            defer testing.allocator.free(text);
            try testing.expectEqualStrings(expected, text);
        } else reference = text;
    }
}

fn describe(set: *ModSet) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const preview = try set.preview();
    for (preview.order) |e| try w.print("load {s} {s}\n", .{ e.name, e.file });
    for (preview.skipped) |s| try w.print("skip {s} {t} {s}\n", .{ s.name, s.reason, s.file });
    const report = try set.conflicts();
    for (report.packages) |p| try w.print("{d} {d} {d}\n", .{ p.provides, p.wins, p.loses });
    for (report.contested) |r| {
        try w.print("{s}:", .{r.name});
        for (r.providers) |p| try w.print(" {s}", .{preview.order[p].name});
        try w.writeByte('\n');
    }
    return out.toOwnedSlice();
}
