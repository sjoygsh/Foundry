//! Turning what is installed into a load order.
//!
//! **Determinism is the property, not the algorithm** (I9): the same candidates and the
//! same enabled set produce the same order on every machine, every run. Nothing here reads
//! a directory, a clock or a hash map's iteration order, and the test that says so shuffles
//! the discovery order — the only thing a filesystem can vary — and asserts the answer is
//! identical.
//!
//! **A stable topological sort, not a plain one.** Load order is how overrides resolve
//! (`content-schemas.md` §7), so the player's order carries real intent — two mods that
//! both replace a texture are settled by which one is later. The dependency graph
//! constrains the order only where a dependency actually exists; everywhere else the
//! player's order survives, and the package's own id is the final tie-break so that two
//! mods nobody ordered still land somewhere reproducible.
//!
//! **A broken mod is skipped, not fatal.** The rule `content-schemas.md` §7 already set for
//! a patch targeting a missing id: a player with one bad mod should get a game and a
//! message, not a failure to launch. The exception is `required` — there is no game
//! without package zero.
//!
//! **So is a duplicated one, when a player put it there** (ADR-0040). Two packages with one
//! id both shipped with the game is a broken installation and stays fatal. A player's
//! package claiming an installed package's id is skipped and the installed one loads, and
//! two or more of the player's own packages sharing an id are all skipped. Each case names
//! both files; none is a silent pick.
//!
//! Design: `docs/design/public-abi.md` §12.

const std = @import("std");
const core = @import("core");
const data = @import("data");

const discover_mod = @import("discover.zig");
const manifest_mod = @import("manifest.zig");

const Allocator = std.mem.Allocator;
const Candidate = discover_mod.Candidate;
const ContentId = core.ContentId;
const Origin = discover_mod.Origin;
const Diagnostics = data.Diagnostics;

const log = core.log.scoped(.mod);

/// Never selected, and therefore last among equals. Auto-added dependencies get this: the
/// graph already puts them before whatever needed them, so their position only decides how
/// they sort against *other* unordered packages, and there the id decides.
const unordered: u32 = std.math.maxInt(u32);

pub const Error = error{
    /// Two **installed** candidates claim the same id. The application shipped a broken
    /// installation, there is no correct one to choose, and choosing quietly produces a bug
    /// report nobody can reproduce. Duplicates involving a player's package are skips.
    DuplicatePackage,
    /// Something in `required` is not installed.
    RequiredPackageMissing,
    /// Something in `required` had to be skipped — its own dependency is missing, or it is
    /// in a cycle. Fatal for the same reason: there is no game without it.
    RequiredPackageSkipped,
} || Allocator.Error;

pub const SkipReason = enum {
    /// Enabled by the player, and no candidate provides it. A warning rather than a skip
    /// of anything: nothing was going to load, so nothing was dropped.
    not_installed,
    missing_dependency,
    dependency_version,
    dependency_skipped,
    /// In a dependency cycle, or behind one.
    cycle,
    /// Two or more of the player's packages share an id, and none of them loads. Reported
    /// whether or not anything enabled it: it is a fault in what is installed.
    duplicate,
    /// A player's package has the id of one the application installed. The installed one
    /// loads; replacing a package is not content override (ADR-0031).
    shadows_installed,

    pub fn text(self: SkipReason) []const u8 {
        return switch (self) {
            .not_installed => "is enabled but not installed",
            .missing_dependency => "requires a package that is not installed",
            .dependency_version => "requires a version of a package that is not installed",
            .dependency_skipped => "requires a package that was itself skipped",
            .cycle => "is in a dependency cycle, or behind one",
            .duplicate => "shares its id with another of the player's packages, so neither loads",
            .shadows_installed => "has the id of an installed package, which loads instead",
        };
    }
};

pub const Skip = struct {
    id: ContentId,
    /// The spelling, when anything installed knows it. Empty for an enabled id nobody
    /// provides, which is the one case where no file on disk carries the name.
    name: []const u8 = "",
    reason: SkipReason,
    /// The dependency this is about, for the three reasons that have one.
    other: ContentId = .none,
    other_name: []const u8 = "",
    /// The copy this is about, as discovery found it. Empty for `not_installed`, the one
    /// reason with no file, and the only way to tell two duplicated copies apart.
    base_dir: []const u8 = "",
    file: []const u8 = "",
};

/// One package to load, in order. Exactly what `app.Config.content` takes, plus the code-tier
/// descriptors later hosts consume without reopening an untrusted package.
pub const Entry = struct {
    id: ContentId,
    name: []const u8,
    /// The host-assigned directory this package was discovered under. Content cannot
    /// name it; applications preserve it into their content/code adapters.
    base_dir: []const u8,
    file: []const u8,
    root: []const u8,
    version: u32,
    /// The ABI range is checked only after the package's content is live, when phase 5
    /// considers its optional native library. Carry discovery's answer through the
    /// resolved order instead of reopening an untrusted package to ask it again.
    abi: ?manifest_mod.Range = null,
    native: ?[]const u8 = null,
    script: ?manifest_mod.Script = null,
};

pub const Request = struct {
    /// The player's order. Load order is the override mechanism, so this is intent and is
    /// preserved wherever the dependency graph allows.
    enabled: []const ContentId = &.{},
    /// Always loaded, always first, never skippable. `foundry:core` lives here (I3).
    required: []const ContentId = &.{},
};

pub const Resolution = struct {
    arena: core.Arena,
    order: []const Entry = &.{},
    skipped: []const Skip = &.{},

    pub fn deinit(self: *Resolution) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// A group of candidates sharing one id, while duplicates are sorted out.
const Group = struct {
    installed: ?u32 = null,
    /// The first and second of the player's copies, in canonical order: enough to name a
    /// sibling in every diagnostic.
    first_user: ?u32 = null,
    second_user: ?u32 = null,
};

pub fn resolve(
    gpa: Allocator,
    discovered: []const Candidate,
    request: Request,
    diags: *Diagnostics,
) Error!Resolution {
    var out: Resolution = .{ .arena = .init(gpa) };
    errdefer out.arena.deinit();
    const arena = out.arena.allocator();

    // 0. **Canonical order before anything else.** Discovery order is the one thing a
    //    filesystem, or a host combining roots, can vary. Every loop below runs in index
    //    order — which duplicate is named first, which failing dependency a skip reports,
    //    the order skips are listed in — so each has to be a function of the packages
    //    rather than of the order they arrived in (I9).
    const candidates = try gpa.dupe(Candidate, discovered);
    defer gpa.free(candidates);
    std.mem.sort(Candidate, candidates, {}, lessCanonical);

    const n = candidates.len;

    // 1. Index by id, with ADR-0040's three duplicate cases.
    var groups: std.AutoHashMapUnmanaged(u64, Group) = .empty;
    defer groups.deinit(gpa);
    try groups.ensureTotalCapacity(gpa, @intCast(n));
    for (candidates, 0..) |c, i| {
        const gop = groups.getOrPutAssumeCapacity(c.manifest.id.hash);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const group = gop.value_ptr;
        switch (c.origin) {
            .installed => if (group.installed) |first_index| {
                // Named as the skips below are, never by an absolute path: now that a
                // host logs it, this line reaches the session log too.
                const first = candidates[first_index];
                try diags.addFmt(gpa, .err, .whole(c.file), 0, "", "'{s}/{s}' declares the same package id as '{s}/{s}': {s}", .{
                    placeName(c.origin),
                    c.file,
                    placeName(first.origin),
                    first.file,
                    c.manifest.id_name,
                });
                return error.DuplicatePackage;
            } else {
                group.installed = @intCast(i);
            },
            .user => if (group.first_user == null) {
                group.first_user = @intCast(i);
            } else if (group.second_user == null) {
                group.second_user = @intCast(i);
            },
        }
    }

    var by_id: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer by_id.deinit(gpa);
    try by_id.ensureTotalCapacity(gpa, @intCast(n));
    // Why each candidate can never load, whatever was asked for. A player's package that
    // an id's other copies rule out stays in `by_id` when it is the id's only
    // representative, so what depends on it is skipped as depending on a skip rather than
    // on something missing.
    const dropped = try gpa.alloc(?SkipReason, n);
    defer gpa.free(dropped);
    @memset(dropped, null);

    var skips: std.ArrayList(Skip) = .empty;
    defer skips.deinit(gpa);

    for (candidates, 0..) |c, i| {
        const group = groups.get(c.manifest.id.hash).?;
        by_id.putAssumeCapacity(c.manifest.id.hash, group.installed orelse group.first_user.?);
        if (c.origin != .user) continue;

        const reason: SkipReason, const sibling: u32 = if (group.installed) |installed|
            .{ .shadows_installed, installed }
        else if (group.second_user) |second|
            .{ .duplicate, if (group.first_user.? == i) second else group.first_user.? }
        else
            continue;
        dropped[i] = reason;
        try skips.append(gpa, .{
            .id = c.manifest.id,
            .name = c.manifest.id_name,
            .reason = reason,
            .base_dir = c.base_dir,
            .file = c.file,
        });
        // Named by where each copy sits and its file, never by an absolute path: this
        // reaches the session log, which collects no home paths (`distribution.md` §10).
        const other = candidates[sibling];
        switch (reason) {
            .shadows_installed => try diags.addFmt(gpa, .warning, .whole(c.file), 0, "", "'{s}/{s}' declares '{s}', which '{s}/{s}' already provides; the installed package loads instead", .{
                placeName(c.origin), c.file, c.manifest.id_name, placeName(other.origin), other.file,
            }),
            else => try diags.addFmt(gpa, .warning, .whole(c.file), 0, "", "'{s}/{s}' and '{s}/{s}' both declare '{s}'; neither loads", .{
                placeName(c.origin), c.file, placeName(other.origin), other.file, c.manifest.id_name,
            }),
        }
    }

    const pos = try gpa.alloc(u32, n);
    defer gpa.free(pos);
    const selected = try gpa.alloc(bool, n);
    defer gpa.free(selected);
    const ok = try gpa.alloc(bool, n);
    defer gpa.free(ok);
    const placed = try gpa.alloc(bool, n);
    defer gpa.free(placed);
    @memset(pos, unordered);
    @memset(selected, false);
    @memset(ok, true);
    @memset(placed, false);
    for (dropped, ok) |d, *o| {
        if (d != null) o.* = false;
    }

    // 1. Seed. `required` first, so package zero is position zero and stays there unless
    //    something depends on it — which nothing can, because it depends on nothing.
    var next_pos: u32 = 0;
    for (request.required) |id| {
        const index = by_id.get(id.hash) orelse {
            try diags.addFmt(gpa, .err, .whole("<load order>"), 0, "", "required package {x} is not installed", .{id.hash});
            return error.RequiredPackageMissing;
        };
        // Only a player's copies can be dropped; step 6 finds it unplaced, and says so.
        if (dropped[index] != null) continue;
        if (!selected[index]) {
            selected[index] = true;
            pos[index] = next_pos;
            next_pos += 1;
        }
    }
    for (request.enabled) |id| {
        const index = by_id.get(id.hash) orelse {
            try skips.append(gpa, .{ .id = id, .reason = .not_installed });
            try diags.addFmt(gpa, .warning, .whole("<load order>"), 0, "", "enabled package {x} is not installed", .{id.hash});
            continue;
        };
        // Already reported, once, whether or not anything enabled it.
        if (dropped[index] != null) continue;
        if (!selected[index]) {
            selected[index] = true;
            pos[index] = next_pos;
            next_pos += 1;
        }
    }

    // 2. Close over dependencies. A dependency of something enabled is enabled — asking a
    //    player to name every transitive dependency by hand is asking them to be the
    //    resolver.
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(gpa);
    for (0..n) |i| if (selected[i]) try pending.append(gpa, @intCast(i));
    while (pending.pop()) |index| {
        for (candidates[index].manifest.requires) |req| {
            const dep = by_id.get(req.id.hash) orelse continue;
            // A dropped copy pulls in nothing: it is not going to load.
            if (selected[dep] or dropped[dep] != null) continue;
            selected[dep] = true;
            try pending.append(gpa, dep);
        }
    }

    // 3. Validity, to a fixed point. A package whose dependency is skipped is itself
    //    skipped, which has to propagate rather than being checked once.
    var changed = true;
    while (changed) {
        changed = false;
        for (0..n) |i| {
            if (!selected[i] or !ok[i]) continue;
            for (candidates[i].manifest.requires) |req| {
                const dep_index = by_id.get(req.id.hash);
                const reason: SkipReason = blk: {
                    const dep = dep_index orelse break :blk .missing_dependency;
                    // Before the version: a duplicated dependency cannot load at any
                    // version, and which copy's version to quote is not a question to answer.
                    if (dropped[dep] != null) break :blk .dependency_skipped;
                    if (!req.range.accepts(candidates[dep].manifest.version)) break :blk .dependency_version;
                    if (!ok[dep]) break :blk .dependency_skipped;
                    continue;
                };
                ok[i] = false;
                changed = true;
                try skips.append(gpa, .{
                    .id = candidates[i].manifest.id,
                    .name = candidates[i].manifest.id_name,
                    .reason = reason,
                    .other = req.id,
                    .other_name = if (dep_index) |d| candidates[d].manifest.id_name else "",
                    .base_dir = candidates[i].base_dir,
                    .file = candidates[i].file,
                });
                try report(gpa, diags, candidates[i], reason, req.id, dep_index, candidates);
                break;
            }
        }
    }

    // 4. Stable topological sort. Quadratic on purpose: the list is tens of packages, and a
    //    scan for the minimum is the shape whose determinism can be read off the code.
    var order: std.ArrayList(Entry) = .empty;
    defer order.deinit(gpa);

    while (true) {
        var best: ?usize = null;
        for (0..n) |i| {
            if (!selected[i] or !ok[i] or placed[i]) continue;
            if (!dependenciesPlaced(candidates[i], by_id, selected, ok, placed)) continue;
            if (best) |b| {
                if (!lessInOrder(candidates, pos, i, b)) continue;
            }
            best = i;
        }
        const index = best orelse break;
        placed[index] = true;
        const m = candidates[index].manifest;
        try order.append(gpa, .{
            .id = m.id,
            .name = try arena.dupe(u8, m.id_name),
            .base_dir = try arena.dupe(u8, candidates[index].base_dir),
            .file = try arena.dupe(u8, candidates[index].file),
            .root = try arena.dupe(u8, candidates[index].root),
            .version = m.version,
            .abi = m.abi,
            .native = if (m.native) |native| try arena.dupe(u8, native) else null,
            .script = m.script,
        });
    }

    // 5. Whatever could not be placed is in a cycle or behind one. Naming both the same way
    //    is imprecise and honest: from here they are indistinguishable without walking the
    //    graph again to produce a distinction nobody can act on differently.
    for (0..n) |i| {
        if (!selected[i] or !ok[i] or placed[i]) continue;
        try skips.append(gpa, .{
            .id = candidates[i].manifest.id,
            .name = candidates[i].manifest.id_name,
            .reason = .cycle,
            .base_dir = candidates[i].base_dir,
            .file = candidates[i].file,
        });
        try diags.addFmt(gpa, .warning, .whole(candidates[i].file), 0, "", "'{s}' {s}", .{
            candidates[i].manifest.id_name,
            SkipReason.cycle.text(),
        });
    }

    // 6. A required package that did not make it is fatal, checked after everything else so
    //    that the diagnostics explaining *why* are already recorded.
    for (request.required) |id| {
        const index = by_id.get(id.hash).?;
        if (placed[index]) continue;
        try diags.addFmt(gpa, .err, .whole(candidates[index].file), 0, "", "required package '{s}' could not be loaded", .{
            candidates[index].manifest.id_name,
        });
        return error.RequiredPackageSkipped;
    }

    out.order = try arena.dupe(Entry, order.items);

    // The skips still point at the discovery's strings; a resolution outlives a discovery
    // in every caller that keeps one, so it owns what it reports.
    const skipped = try arena.dupe(Skip, skips.items);
    for (skipped) |*s| {
        s.name = try arena.dupe(u8, s.name);
        s.other_name = try arena.dupe(u8, s.other_name);
        s.base_dir = try arena.dupe(u8, s.base_dir);
        s.file = try arena.dupe(u8, s.file);
    }
    out.skipped = skipped;
    log.debug("resolved {d} packages, skipped {d}", .{ out.order.len, out.skipped.len });
    return out;
}

/// The canonical order: the id's spelling, then where the copy sits. A total order over
/// anything discovery can return, since one root holds one file of one name.
fn lessCanonical(_: void, a: Candidate, b: Candidate) bool {
    switch (std.mem.order(u8, a.manifest.id_name, b.manifest.id_name)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (a.origin != b.origin) return @intFromEnum(a.origin) < @intFromEnum(b.origin);
    switch (std.mem.order(u8, a.base_dir, b.base_dir)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    return std.mem.order(u8, a.file, b.file) == .lt;
}

/// How a diagnostic names a root: by whose it is, not where it is on this machine.
fn placeName(origin: Origin) []const u8 {
    return switch (origin) {
        .installed => "installed",
        .user => "mods",
    };
}

fn dependenciesPlaced(
    candidate: Candidate,
    by_id: std.AutoHashMapUnmanaged(u64, u32),
    selected: []const bool,
    ok: []const bool,
    placed: []const bool,
) bool {
    for (candidate.manifest.requires) |req| {
        const dep = by_id.get(req.id.hash) orelse continue;
        if (!selected[dep] or !ok[dep]) continue;
        if (!placed[dep]) return false;
    }
    return true;
}

/// The tie-break, in one place: the player's position, then the package's own id.
///
/// The id is compared **as its spelling** rather than as its hash. Both are deterministic;
/// only one is explicable to a mod author looking at the order and asking why.
fn lessInOrder(candidates: []const Candidate, pos: []const u32, a: usize, b: usize) bool {
    if (pos[a] != pos[b]) return pos[a] < pos[b];
    return std.mem.order(u8, candidates[a].manifest.id_name, candidates[b].manifest.id_name) == .lt;
}

fn report(
    gpa: Allocator,
    diags: *Diagnostics,
    candidate: Candidate,
    reason: SkipReason,
    dep_id: ContentId,
    dep_index: ?u32,
    candidates: []const Candidate,
) Allocator.Error!void {
    if (dep_index) |d| {
        try diags.addFmt(gpa, .warning, .whole(candidate.file), 0, "", "'{s}' {s}: '{s}' version {d}", .{
            candidate.manifest.id_name,
            reason.text(),
            candidates[d].manifest.id_name,
            candidates[d].manifest.version,
        });
    } else {
        // The one diagnostic that can only print a number: an `id` field is eight bytes in
        // a compiled package and the spelling lives in the author's source, not here.
        try diags.addFmt(gpa, .warning, .whole(candidate.file), 0, "", "'{s}' {s} (id {x})", .{
            candidate.manifest.id_name,
            reason.text(),
            dep_id.hash,
        });
    }
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

const TestPackage = struct {
    name: []const u8,
    base_dir: []const u8 = "test-root",
    origin: Origin = .installed,
    /// Defaults to the id's spelling with `.fpk`; two copies of one id need two files.
    file: ?[]const u8 = null,
    version: u32 = 1,
    requires: []const []const u8 = &.{},
    /// Version ranges, parallel to `requires`. Empty means "any".
    ranges: []const manifestRange = &.{},
};

const manifestRange = @import("manifest.zig").Range;

fn makeCandidate(arena: Allocator, spec: TestPackage) !Candidate {
    const reqs = try arena.alloc(@import("manifest.zig").Requirement, spec.requires.len);
    for (reqs, spec.requires, 0..) |*r, name, i| r.* = .{
        .id = try data.contentId(name),
        .range = if (i < spec.ranges.len) spec.ranges[i] else .{},
    };
    return .{
        .manifest = .{
            .id = try data.contentId(spec.name),
            .id_name = spec.name,
            .version = spec.version,
            .name = spec.name,
            .license = "MIT",
            .requires = reqs,
        },
        .base_dir = spec.base_dir,
        .file = spec.file orelse try std.fmt.allocPrint(arena, "{s}.fpk", .{spec.name}),
        .root = spec.name,
        .origin = spec.origin,
    };
}

fn makeAll(arena: Allocator, specs: []const TestPackage) ![]Candidate {
    const out = try arena.alloc(Candidate, specs.len);
    for (out, specs) |*c, spec| c.* = try makeCandidate(arena, spec);
    return out;
}

fn ids(arena: Allocator, names: []const []const u8) ![]ContentId {
    const out = try arena.alloc(ContentId, names.len);
    for (out, names) |*id, name| id.* = try data.contentId(name);
    return out;
}

fn orderNames(res: Resolution, buf: [][]const u8) [][]const u8 {
    for (res.order, 0..) |e, i| buf[i] = e.name;
    return buf[0..res.order.len];
}

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    diags: Diagnostics,

    fn init() Harness {
        return .{
            .arena = .init(testing.allocator),
            .diags = .init(testing.allocator, .default),
        };
    }
    fn deinit(self: *Harness) void {
        self.diags.deinit(testing.allocator);
        self.arena.deinit();
    }
    fn a(self: *Harness) Allocator {
        return self.arena.allocator();
    }
};

test "a dependency loads before what needs it, whatever the player asked for" {
    var h: Harness = .init();
    defer h.deinit();

    const candidates = try makeAll(h.a(), &.{
        .{ .name = "a:lamps", .requires = &.{"foundry:core"} },
        .{ .name = "foundry:core" },
    });

    // The player put the mod first. The graph says otherwise, and the graph wins — but only
    // where it actually constrains the answer.
    var res = try resolve(testing.allocator, candidates, .{
        .required = try ids(h.a(), &.{"foundry:core"}),
        .enabled = try ids(h.a(), &.{"a:lamps"}),
    }, &h.diags);
    defer res.deinit();

    var buf: [8][]const u8 = undefined;
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "foundry:core", "a:lamps" }), orderNames(res, &buf));
    try testing.expectEqualStrings("test-root", res.order[0].base_dir);
    try testing.expectEqualStrings("test-root", res.order[1].base_dir);
}

test "the player's order survives where the graph does not constrain it" {
    var h: Harness = .init();
    defer h.deinit();

    // Two mods, neither depending on the other. Load order is the override mechanism, so
    // which one is later is the player's decision and nothing else's.
    const candidates = try makeAll(h.a(), &.{
        .{ .name = "foundry:core" },
        .{ .name = "a:first" },
        .{ .name = "z:second" },
    });
    const required = try ids(h.a(), &.{"foundry:core"});

    var forward = try resolve(testing.allocator, candidates, .{
        .required = required,
        .enabled = try ids(h.a(), &.{ "a:first", "z:second" }),
    }, &h.diags);
    defer forward.deinit();

    var backward = try resolve(testing.allocator, candidates, .{
        .required = required,
        .enabled = try ids(h.a(), &.{ "z:second", "a:first" }),
    }, &h.diags);
    defer backward.deinit();

    var b1: [8][]const u8 = undefined;
    var b2: [8][]const u8 = undefined;
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "foundry:core", "a:first", "z:second" }), orderNames(forward, &b1));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "foundry:core", "z:second", "a:first" }), orderNames(backward, &b2));
}

test "the same packages in a different discovery order produce the same load order" {
    var h: Harness = .init();
    defer h.deinit();

    // Discovery order is the one thing a filesystem can vary, so it is the one thing the
    // answer must not depend on (I9). None of these are in the enabled list — they arrive
    // as dependencies, which is the case with no player order to fall back on and therefore
    // the case where the tie-break is actually doing the work.
    const forward = try makeAll(h.a(), &.{
        .{ .name = "foundry:core" },
        .{ .name = "m:one", .requires = &.{"foundry:core"} },
        .{ .name = "m:two", .requires = &.{"foundry:core"} },
        .{ .name = "m:three", .requires = &.{"foundry:core"} },
        .{ .name = "top:mod", .requires = &.{ "m:one", "m:two", "m:three" } },
    });
    const reversed = try makeAll(h.a(), &.{
        .{ .name = "top:mod", .requires = &.{ "m:one", "m:two", "m:three" } },
        .{ .name = "m:three", .requires = &.{"foundry:core"} },
        .{ .name = "m:two", .requires = &.{"foundry:core"} },
        .{ .name = "m:one", .requires = &.{"foundry:core"} },
        .{ .name = "foundry:core" },
    });

    const request: Request = .{
        .required = try ids(h.a(), &.{"foundry:core"}),
        .enabled = try ids(h.a(), &.{"top:mod"}),
    };

    var a_res = try resolve(testing.allocator, forward, request, &h.diags);
    defer a_res.deinit();
    var b_res = try resolve(testing.allocator, reversed, request, &h.diags);
    defer b_res.deinit();

    var b1: [8][]const u8 = undefined;
    var b2: [8][]const u8 = undefined;
    const a_names = orderNames(a_res, &b1);
    const b_names = orderNames(b_res, &b2);
    try testing.expectEqualDeep(a_names, b_names);

    // And the tie-break is the id's spelling, not the order they were found in: `m:one`,
    // `m:three`, `m:two` is alphabetical and is what a mod author can predict.
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "foundry:core", "m:one", "m:three", "m:two", "top:mod" }),
        a_names,
    );
}

test "a missing dependency skips the dependent, and everything behind it" {
    var h: Harness = .init();
    defer h.deinit();

    const candidates = try makeAll(h.a(), &.{
        .{ .name = "foundry:core" },
        .{ .name = "a:base", .requires = &.{"never:installed"} },
        .{ .name = "b:onto", .requires = &.{"a:base"} },
        .{ .name = "c:fine" },
    });

    var res = try resolve(testing.allocator, candidates, .{
        .required = try ids(h.a(), &.{"foundry:core"}),
        .enabled = try ids(h.a(), &.{ "a:base", "b:onto", "c:fine" }),
    }, &h.diags);
    defer res.deinit();

    // The unaffected mod still loads. A player with one broken mod gets a game and a
    // message, not a failure to launch.
    var buf: [8][]const u8 = undefined;
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "foundry:core", "c:fine" }), orderNames(res, &buf));

    try testing.expectEqual(@as(usize, 2), res.skipped.len);
    try testing.expectEqual(SkipReason.missing_dependency, res.skipped[0].reason);
    try testing.expectEqualStrings("a:base", res.skipped[0].name);
    try testing.expectEqual(SkipReason.dependency_skipped, res.skipped[1].reason);
    try testing.expectEqualStrings("b:onto", res.skipped[1].name);
    try testing.expect(!h.diags.failed);
}

test "a dependency at a version outside the range is skipped, and the diagnostic names the version" {
    var h: Harness = .init();
    defer h.deinit();

    const candidates = try makeAll(h.a(), &.{
        .{ .name = "foundry:core" },
        .{ .name = "a:old", .version = 1 },
        .{ .name = "b:wants", .requires = &.{"a:old"}, .ranges = &.{.{ .min = 2 }} },
    });

    var res = try resolve(testing.allocator, candidates, .{
        .required = try ids(h.a(), &.{"foundry:core"}),
        .enabled = try ids(h.a(), &.{ "a:old", "b:wants" }),
    }, &h.diags);
    defer res.deinit();

    var buf: [8][]const u8 = undefined;
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "foundry:core", "a:old" }), orderNames(res, &buf));
    try testing.expectEqual(@as(usize, 1), res.skipped.len);
    try testing.expectEqual(SkipReason.dependency_version, res.skipped[0].reason);
    try testing.expectEqualStrings("a:old", res.skipped[0].other_name);
}

test "a cycle skips everyone in it and the game still starts" {
    var h: Harness = .init();
    defer h.deinit();

    const candidates = try makeAll(h.a(), &.{
        .{ .name = "foundry:core" },
        .{ .name = "a:one", .requires = &.{"b:two"} },
        .{ .name = "b:two", .requires = &.{"a:one"} },
        .{ .name = "c:fine" },
    });

    var res = try resolve(testing.allocator, candidates, .{
        .required = try ids(h.a(), &.{"foundry:core"}),
        .enabled = try ids(h.a(), &.{ "a:one", "b:two", "c:fine" }),
    }, &h.diags);
    defer res.deinit();

    var buf: [8][]const u8 = undefined;
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "foundry:core", "c:fine" }), orderNames(res, &buf));
    try testing.expectEqual(@as(usize, 2), res.skipped.len);
    for (res.skipped) |s| try testing.expectEqual(SkipReason.cycle, s.reason);
}

test "two installed packages claiming one id is an error naming both files" {
    var h: Harness = .init();
    defer h.deinit();

    const candidates = try makeAll(h.a(), &.{
        .{ .name = "foundry:core" },
        .{ .name = "a:twice", .base_dir = "installed", .file = "twice.fpk", .version = 1 },
        .{ .name = "a:twice", .base_dir = "second-install", .file = "twice-again.fpk", .version = 2 },
    });

    // Both shipped with the application: a broken installation, not a player's mistake,
    // and choosing one quietly produces a bug report nobody can reproduce.
    try testing.expectError(error.DuplicatePackage, resolve(testing.allocator, candidates, .{
        .required = try ids(h.a(), &.{"foundry:core"}),
    }, &h.diags));
    try testing.expect(h.diags.failed);
    try testing.expect(std.mem.indexOf(u8, h.diags.items.items[0].message, "'installed/twice.fpk'") != null);
    try testing.expect(std.mem.indexOf(u8, h.diags.items.items[0].message, "'installed/twice-again.fpk'") != null);
    try testing.expect(std.mem.indexOf(u8, h.diags.items.items[0].message, "second-install") == null);
}

test "a player's package claiming an installed id is skipped, and the installed one loads" {
    var h: Harness = .init();
    defer h.deinit();

    const candidates = try makeAll(h.a(), &.{
        .{ .name = "foundry:core" },
        .{ .name = "a:thing", .base_dir = "install", .version = 1 },
        .{ .name = "a:thing", .base_dir = "user", .origin = .user, .file = "thing-v2.fpk", .version = 2 },
        // A copy of package zero in `mods/` is the same case, not a way to replace it.
        .{ .name = "foundry:core", .base_dir = "user", .origin = .user, .file = "core.fpk" },
    });

    var res = try resolve(testing.allocator, candidates, .{
        .required = try ids(h.a(), &.{"foundry:core"}),
        .enabled = try ids(h.a(), &.{"a:thing"}),
    }, &h.diags);
    defer res.deinit();

    var buf: [8][]const u8 = undefined;
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "foundry:core", "a:thing" }), orderNames(res, &buf));
    try testing.expectEqualStrings("install", res.order[1].base_dir);
    try testing.expectEqual(@as(u32, 1), res.order[1].version);
    try testing.expectEqualStrings("test-root", res.order[0].base_dir);

    try testing.expectEqual(@as(usize, 2), res.skipped.len);
    for (res.skipped) |skip| {
        try testing.expectEqual(SkipReason.shadows_installed, skip.reason);
        try testing.expectEqualStrings("user", skip.base_dir);
    }
    try testing.expectEqualStrings("thing-v2.fpk", res.skipped[0].file);
    try testing.expectEqualStrings("core.fpk", res.skipped[1].file);

    // A message, not a failure; both files named, and by whose they are rather than where.
    try testing.expect(!h.diags.failed);
    try testing.expectEqual(@as(usize, 2), h.diags.count());
    const message = h.diags.items.items[0].message;
    try testing.expect(std.mem.indexOf(u8, message, "mods/thing-v2.fpk") != null);
    try testing.expect(std.mem.indexOf(u8, message, "installed/a:thing.fpk") != null);
    try testing.expect(std.mem.indexOf(u8, message, "user/") == null);
}

test "the player's own packages sharing an id are all skipped, with what needs them" {
    var h: Harness = .init();
    defer h.deinit();

    const candidates = try makeAll(h.a(), &.{
        .{ .name = "foundry:core" },
        .{ .name = "a:twice", .base_dir = "user", .origin = .user, .file = "twice.fpk", .version = 1 },
        .{ .name = "a:twice", .base_dir = "user", .origin = .user, .file = "twice copy.fpk", .version = 3 },
        .{ .name = "a:twice", .base_dir = "user", .origin = .user, .file = "twice (2).fpk", .version = 2 },
        .{ .name = "b:needs", .base_dir = "user", .origin = .user, .requires = &.{"a:twice"}, .ranges = &.{.{ .min = 9 }} },
        .{ .name = "c:fine", .base_dir = "user", .origin = .user },
        // Never enabled, and still reported: two copies is a fault in what is installed.
        .{ .name = "d:idle", .base_dir = "user", .origin = .user, .file = "idle.fpk" },
        .{ .name = "d:idle", .base_dir = "user", .origin = .user, .file = "idle2.fpk" },
    });

    var res = try resolve(testing.allocator, candidates, .{
        .required = try ids(h.a(), &.{"foundry:core"}),
        .enabled = try ids(h.a(), &.{ "a:twice", "b:needs", "c:fine" }),
    }, &h.diags);
    defer res.deinit();

    // One copy is not chosen. The mod nobody duplicated still loads.
    var buf: [8][]const u8 = undefined;
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "foundry:core", "c:fine" }), orderNames(res, &buf));

    try testing.expectEqual(@as(usize, 6), res.skipped.len);
    const files = [_][]const u8{ "twice (2).fpk", "twice copy.fpk", "twice.fpk" };
    for (res.skipped[0..3], files) |skip, file| {
        try testing.expectEqual(SkipReason.duplicate, skip.reason);
        try testing.expectEqualStrings("a:twice", skip.name);
        try testing.expectEqualStrings(file, skip.file);
    }
    try testing.expectEqual(SkipReason.duplicate, res.skipped[3].reason);
    try testing.expectEqualStrings("idle.fpk", res.skipped[3].file);
    try testing.expectEqual(SkipReason.duplicate, res.skipped[4].reason);
    try testing.expectEqualStrings("idle2.fpk", res.skipped[4].file);
    // The dependent is skipped as depending on a skip, whatever range it asked for: no
    // copy's version is the one to quote.
    try testing.expectEqual(SkipReason.dependency_skipped, res.skipped[5].reason);
    try testing.expectEqualStrings("b:needs", res.skipped[5].name);
    try testing.expectEqualStrings("a:twice", res.skipped[5].other_name);

    // Nothing reports the duplicated id as not installed, and nothing is fatal.
    try testing.expect(!h.diags.failed);
    try testing.expectEqual(@as(usize, 6), h.diags.count());
    try testing.expect(std.mem.indexOf(u8, h.diags.items.items[0].message, "'mods/twice (2).fpk' and 'mods/twice copy.fpk'") != null);
}

test "a required package the player duplicated is still fatal" {
    var h: Harness = .init();
    defer h.deinit();

    // Only a host would ever require a user package, and then it is required all the same.
    const candidates = try makeAll(h.a(), &.{
        .{ .name = "foundry:core", .base_dir = "user", .origin = .user, .file = "core.fpk" },
        .{ .name = "foundry:core", .base_dir = "user", .origin = .user, .file = "core copy.fpk" },
    });
    try testing.expectError(error.RequiredPackageSkipped, resolve(testing.allocator, candidates, .{
        .required = try ids(h.a(), &.{"foundry:core"}),
    }, &h.diags));
    try testing.expect(h.diags.failed);
}

test "shuffled candidates give byte-identical resolutions, skips and diagnostics included" {
    var h: Harness = .init();
    defer h.deinit();

    // Every kind of outcome at once, so that any loop whose answer followed its input
    // order would show it: duplicates of both kinds, a missing dependency behind which a
    // second package is skipped, a version range, a cycle, and unordered dependencies.
    const specs = [_]TestPackage{
        .{ .name = "foundry:core" },
        .{ .name = "g:game", .requires = &.{"foundry:core"} },
        .{ .name = "g:game", .base_dir = "user", .origin = .user, .file = "game.fpk" },
        .{ .name = "a:twice", .base_dir = "user", .origin = .user, .file = "twice.fpk" },
        .{ .name = "a:twice", .base_dir = "user", .origin = .user, .file = "twice2.fpk", .version = 2 },
        .{ .name = "b:onto", .base_dir = "user", .origin = .user, .requires = &.{ "c:gone", "a:twice" } },
        .{ .name = "c:behind", .base_dir = "user", .origin = .user, .requires = &.{"b:onto"} },
        .{ .name = "d:old", .base_dir = "user", .origin = .user },
        .{ .name = "e:wants", .base_dir = "user", .origin = .user, .requires = &.{"d:old"}, .ranges = &.{.{ .min = 4 }} },
        .{ .name = "f:one", .base_dir = "user", .origin = .user, .requires = &.{"f:two"} },
        .{ .name = "f:two", .base_dir = "user", .origin = .user, .requires = &.{"f:one"} },
        .{ .name = "h:dep1", .base_dir = "user", .origin = .user },
        .{ .name = "h:dep2", .base_dir = "user", .origin = .user },
        .{ .name = "i:top", .base_dir = "user", .origin = .user, .requires = &.{ "h:dep2", "h:dep1" } },
    };
    const request: Request = .{
        .required = try ids(h.a(), &.{ "foundry:core", "g:game" }),
        .enabled = try ids(h.a(), &.{ "i:top", "e:wants", "c:behind", "f:one", "b:onto", "a:twice", "d:old", "gone:mod" }),
    };

    var reference: ?[]const u8 = null;
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    for (0..12) |round| {
        var shuffled = specs;
        if (round == 1) std.mem.reverse(TestPackage, &shuffled) else if (round > 1) prng.random().shuffle(TestPackage, &shuffled);

        var diags: Diagnostics = .init(testing.allocator, .default);
        defer diags.deinit(testing.allocator);
        var res = try resolve(testing.allocator, try makeAll(h.a(), &shuffled), request, &diags);
        defer res.deinit();

        const text = try describe(h.a(), res, diags);
        if (reference) |expected| {
            try testing.expectEqualStrings(expected, text);
        } else reference = text;
    }
}

/// Everything a resolution says, and every diagnostic, as one string to compare.
fn describe(arena: Allocator, res: Resolution, diags: Diagnostics) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    for (res.order) |e| try w.print("load {s} v{d} {s}/{s}\n", .{ e.name, e.version, e.base_dir, e.file });
    for (res.skipped) |s| try w.print("skip {s} {t} {s} {s}/{s}\n", .{ s.name, s.reason, s.other_name, s.base_dir, s.file });
    for (diags.items.items) |d| try w.print("diag {t} {s}\n", .{ d.severity, d.message });
    return out.written();
}

test "a required package that is not installed is fatal, and one that is skipped is too" {
    var h: Harness = .init();
    defer h.deinit();

    const empty = try makeAll(h.a(), &.{.{ .name = "a:something" }});
    try testing.expectError(error.RequiredPackageMissing, resolve(testing.allocator, empty, .{
        .required = try ids(h.a(), &.{"foundry:core"}),
    }, &h.diags));

    var h2: Harness = .init();
    defer h2.deinit();
    const broken = try makeAll(h2.a(), &.{.{ .name = "foundry:core", .requires = &.{"never:installed"} }});
    try testing.expectError(error.RequiredPackageSkipped, resolve(testing.allocator, broken, .{
        .required = try ids(h2.a(), &.{"foundry:core"}),
    }, &h2.diags));
}

test "an enabled package nobody has is a warning, and nothing else stops" {
    var h: Harness = .init();
    defer h.deinit();

    const candidates = try makeAll(h.a(), &.{
        .{ .name = "foundry:core" },
        .{ .name = "a:present" },
    });

    var res = try resolve(testing.allocator, candidates, .{
        .required = try ids(h.a(), &.{"foundry:core"}),
        .enabled = try ids(h.a(), &.{ "a:present", "gone:mod" }),
    }, &h.diags);
    defer res.deinit();

    var buf: [8][]const u8 = undefined;
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "foundry:core", "a:present" }), orderNames(res, &buf));
    try testing.expectEqual(@as(usize, 1), res.skipped.len);
    try testing.expectEqual(SkipReason.not_installed, res.skipped[0].reason);
    // Uninstalling a mod you left enabled is housekeeping, not a fault.
    try testing.expect(!h.diags.failed);
}

test "a package nobody enabled is simply not loaded, without a word said about it" {
    var h: Harness = .init();
    defer h.deinit();

    const candidates = try makeAll(h.a(), &.{
        .{ .name = "foundry:core" },
        .{ .name = "a:off" },
    });

    var res = try resolve(testing.allocator, candidates, .{
        .required = try ids(h.a(), &.{"foundry:core"}),
    }, &h.diags);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 1), res.order.len);
    try testing.expectEqual(@as(usize, 0), res.skipped.len);
    try testing.expectEqual(@as(usize, 0), h.diags.count());
}
