//! Who overrides whom, read from what each package says it provides, loading nothing.
//!
//! **Exact, not estimated.** Load order is the whole override rule: of every package
//! providing one content id, the last in the order wins (`content-schemas.md` §7), and a
//! compiled package's record table lists every id it provides (§5.1). So a report over an
//! order and those tables is the answer the store will reach, not a heuristic over file
//! paths. Assets are records (ADR-0021), so an asset conflict is a record conflict.
//!
//! Two things are not conflicts. A package's **manifest** is a record whose id is the
//! package's own, so it cannot collide, and it is left out. A **schema** another package
//! extends is not a record at all (`public-abi.md` §11.3): it adds fields and replaces
//! nothing, so it never appears here.
//!
//! Like discovery, this opens each package alone and reads it as untrusted input: a
//! package that cannot be read is a diagnostic and contributes nothing, never a failure.
//!
//! Design: `docs/design/mod-management.md` §7.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");

const discover_mod = @import("discover.zig");
const resolve_mod = @import("resolve.zig");
const schemas = @import("schemas.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Diagnostics = data.Diagnostics;
const Entry = resolve_mod.Entry;
const Os = platform.os.Os;

const log = core.log.scoped(.mod);

/// What one package of the order does to the others.
pub const Package = struct {
    id: ContentId,
    /// Every record it provides, its manifest aside, contested or not.
    provides: u32 = 0,
    /// Records it provides that override an earlier package's.
    wins: u32 = 0,
    /// Records it provides that a later package overrides.
    loses: u32 = 0,
    /// False when its record table could not be read. A diagnostic says why, and it
    /// provides nothing here.
    readable: bool = true,

    /// Every record it provides is overridden, so it contributes nothing to the game.
    pub fn redundant(self: Package) bool {
        return self.provides > 0 and self.loses == self.provides;
    }
};

/// A record two or more packages provide.
pub const Record = struct {
    id: ContentId,
    /// The spelling, as the package that first contested it wrote it.
    name: []const u8,
    /// Indices into `Conflicts.packages`, in load order. The last one wins.
    providers: []const u32,

    pub fn winner(self: Record) u32 {
        return self.providers[self.providers.len - 1];
    }
};

const Span = struct { start: u32, len: u32 };

pub const Conflicts = struct {
    arena: core.Arena,
    /// One per package of the order, by the same index.
    packages: []const Package = &.{},
    /// Every contested record, sorted by spelling. A record only one package provides is
    /// counted in its `provides` and not listed.
    contested: []const Record = &.{},
    /// Every record the order provides, and where its providers sit in `chains`.
    index: std.AutoHashMapUnmanaged(u64, Span) = .empty,
    chains: []const u32 = &.{},

    pub fn deinit(self: *Conflicts) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Every package providing `id`, as indices into `packages` in load order; the last
    /// wins. Empty when nothing in the order provides it.
    pub fn providers(self: *const Conflicts, id: ContentId) []const u32 {
        const span = self.index.get(id.hash) orelse return &.{};
        return self.chains[span.start..][0..span.len];
    }
};

/// One (record, package) pair while the tables are being read.
const Pair = struct {
    hash: u64,
    package: u32,

    fn less(_: void, a: Pair, b: Pair) bool {
        if (a.hash != b.hash) return a.hash < b.hash;
        return a.package < b.package;
    }
};

/// While reading: the last package seen providing an id, and its spelling once contested.
const Seen = struct {
    last: u32,
    name: ?[]const u8 = null,
};

/// Computes the report over `order`, which is a resolution's load order.
///
/// Cost is one read of each package's record table, bounded by `options`, with nothing
/// decoded but the table and the schemas `data.fpk.Reader` validates.
pub fn compute(
    gpa: Allocator,
    os: *Os,
    order: []const Entry,
    options: discover_mod.Options,
    diags: *Diagnostics,
) Allocator.Error!Conflicts {
    var out: Conflicts = .{ .arena = .init(gpa) };
    errdefer out.arena.deinit();
    const arena = out.arena.allocator();

    const packages = try arena.alloc(Package, order.len);
    for (packages, order) |*p, entry| p.* = .{ .id = entry.id };

    var seen: std.AutoHashMapUnmanaged(u64, Seen) = .empty;
    defer seen.deinit(gpa);
    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(gpa);

    for (order, 0..) |entry, i| {
        const index: u32 = @intCast(i);
        const read = os.readFileConfined(gpa, entry.base_dir, entry.file, options.max_package_bytes) catch |err| {
            packages[i].readable = false;
            try diags.addFmt(gpa, .warning, .whole(entry.file), 0, "", "'{s}' could not be read for its conflicts: {s}", .{ entry.name, @errorName(err) });
            continue;
        };
        defer gpa.free(read.bytes);
        var reader = data.fpk.Reader.open(gpa, read.bytes, options.limits) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                packages[i].readable = false;
                try diags.addFmt(gpa, .warning, .whole(entry.file), 0, "", "'{s}' is no longer a readable package: {s}", .{ entry.name, @errorName(err) });
                continue;
            },
        };
        defer reader.deinit();

        var r: u32 = 0;
        while (reader.record(r)) |view| : (r += 1) {
            if (view.schema_id.eql(schemas.manifest.id)) continue;
            const gop = try seen.getOrPut(gpa, view.id.hash);
            if (gop.found_existing) {
                // Twice in one table is one provision, not a conflict with itself.
                if (gop.value_ptr.last == index) continue;
                gop.value_ptr.last = index;
                if (gop.value_ptr.name == null) gop.value_ptr.name = try arena.dupe(u8, view.name);
            } else {
                gop.value_ptr.* = .{ .last = index };
            }
            try pairs.append(gpa, .{ .hash = view.id.hash, .package = index });
            packages[i].provides += 1;
        }
    }

    // Grouped by id, each group in load order. The hash is only the grouping key: nothing
    // a reader sees is ordered by it.
    std.mem.sort(Pair, pairs.items, {}, Pair.less);
    const chains = try arena.alloc(u32, pairs.items.len);
    try out.index.ensureTotalCapacity(arena, seen.count());
    var contested: std.ArrayList(Record) = .empty;
    defer contested.deinit(gpa);

    var start: usize = 0;
    while (start < pairs.items.len) {
        const hash = pairs.items[start].hash;
        var end = start;
        while (end < pairs.items.len and pairs.items[end].hash == hash) : (end += 1) {
            chains[end] = pairs.items[end].package;
        }
        const chain = chains[start..end];
        out.index.putAssumeCapacity(hash, .{ .start = @intCast(start), .len = @intCast(chain.len) });
        if (chain.len > 1) {
            for (chain, 0..) |p, k| {
                if (k > 0) packages[p].wins += 1;
                if (k + 1 < chain.len) packages[p].loses += 1;
            }
            try contested.append(gpa, .{
                .id = .{ .hash = hash },
                .name = seen.get(hash).?.name.?,
                .providers = chain,
            });
        }
        start = end;
    }

    std.mem.sort(Record, contested.items, {}, lessByName);
    out.contested = try arena.dupe(Record, contested.items);
    out.chains = chains;
    out.packages = packages;
    log.debug("conflicts over {d} packages: {d} records contested", .{ order.len, out.contested.len });
    return out;
}

fn lessByName(_: void, a: Record, b: Record) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    os: *Os,
    registry: data.Registry,
    diags: Diagnostics,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(testing.io, &path_buf);
        const root = try testing.allocator.dupe(u8, path_buf[0..len]);
        errdefer testing.allocator.free(root);
        const os = try Os.init(testing.allocator, .{});
        errdefer os.deinit();
        var registry: data.Registry = .init(testing.allocator, .default);
        errdefer registry.deinit(testing.allocator);
        try schemas.registerAll(testing.allocator, &registry);
        return .{ .tmp = tmp, .root = root, .os = os, .registry = registry, .diags = .init(testing.allocator, .default) };
    }

    fn deinit(self: *Fixture) void {
        self.diags.deinit(testing.allocator);
        self.registry.deinit(testing.allocator);
        self.os.deinit();
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    /// Compiles `source` as package `name` into `<root>/<stem>.fpk`.
    fn package(self: *Fixture, name: []const u8, source: []const u8) !void {
        const gpa = testing.allocator;
        const colon = std.mem.indexOfScalar(u8, name, ':').?;
        var doc = try data.parser.parse(gpa, "test.fdt", source, .{ .namespace = name[0..colon] }, &self.diags);
        defer doc.deinit(gpa);
        var package_build = try data.check.Package.init(gpa, name, 1, .default);
        defer package_build.deinit(gpa);
        try package_build.addDocument(gpa, &doc, &self.registry, &self.diags);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try data.fpk.write(gpa, &package_build, &self.registry, &bytes);
        const file = try std.fmt.allocPrint(gpa, "{s}.fpk", .{name[0..colon]});
        defer gpa.free(file);
        const path = try platform.os.joinPath(gpa, &.{ self.root, file });
        defer gpa.free(path);
        try self.os.writeFile(path, bytes.items);
    }

    /// The four packages every test here uses. `base` owns three records; the three mods
    /// override some of them.
    fn standard(self: *Fixture) !void {
        try self.package("base:content",
            \\foundry:mod base:content { name "Base" version 1 license "MIT" }
            \\@schema base:thing { v u32 }
            \\base:thing base:one { v 1 }
            \\base:thing base:two { v 2 }
            \\base:thing base:three { v 3 }
        );
        try self.package("lamps:content",
            \\foundry:mod lamps:content { name "Lamps" version 1 license "MIT" requires [ { id base:content } ] }
            \\base:thing base:one { v 10 }
            \\base:thing lamps:own { v 11 }
        );
        try self.package("old:content",
            \\foundry:mod old:content { name "Old" version 1 license "MIT" requires [ { id base:content } ] }
            \\base:thing base:two { v 20 }
        );
        try self.package("night:content",
            \\foundry:mod night:content { name "Night" version 1 license "MIT" requires [ { id base:content } ] }
            \\base:thing base:one { v 30 }
            \\base:thing base:two { v 31 }
        );
        try testing.expect(!self.diags.failed);
    }

    fn resolveOrder(self: *Fixture, candidates: []const discover_mod.Candidate, enabled: []const []const u8) !resolve_mod.Resolution {
        var ids: [8]ContentId = undefined;
        for (enabled, 0..) |name, i| ids[i] = ContentId.fromString(name);
        return resolve_mod.resolve(testing.allocator, candidates, .{
            .required = &.{ContentId.fromString("base:content")},
            .enabled = ids[0..enabled.len],
        }, &self.diags);
    }
};

fn packageNamed(res: resolve_mod.Resolution, report: Conflicts, name: []const u8) Package {
    for (res.order, report.packages) |entry, p| if (std.mem.eql(u8, entry.name, name)) return p;
    unreachable;
}

test "the last provider in load order wins, and each package's counts say so" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();

    var found = try discover_mod.discover(testing.allocator, f.os, f.root, .{}, &f.diags);
    defer found.deinit();
    var res = try f.resolveOrder(found.candidates, &.{ "lamps:content", "old:content", "night:content" });
    defer res.deinit();

    var report = try compute(testing.allocator, f.os, res.order, .{}, &f.diags);
    defer report.deinit();

    // Two records are contested, listed by spelling, each with its providers in order.
    try testing.expectEqual(@as(usize, 2), report.contested.len);
    try testing.expectEqualStrings("base:one", report.contested[0].name);
    try testing.expectEqualStrings("base:two", report.contested[1].name);
    try testing.expectEqualStrings("night:content", res.order[report.contested[0].winner()].name);
    try testing.expectEqualDeep(@as([]const u32, &.{ 0, 1, 3 }), report.contested[0].providers);
    try testing.expectEqualDeep(@as([]const u32, &.{ 0, 2, 3 }), report.contested[1].providers);

    const base = packageNamed(res, report, "base:content");
    try testing.expectEqual(Package{ .id = base.id, .provides = 3, .wins = 0, .loses = 2 }, base);
    const lamps = packageNamed(res, report, "lamps:content");
    try testing.expectEqual(Package{ .id = lamps.id, .provides = 2, .wins = 1, .loses = 1 }, lamps);
    const night = packageNamed(res, report, "night:content");
    try testing.expectEqual(Package{ .id = night.id, .provides = 2, .wins = 2, .loses = 0 }, night);

    // Everything `old` provides, `night` replaces: MO2's grey flag.
    const old = packageNamed(res, report, "old:content");
    try testing.expect(old.redundant());
    try testing.expect(!lamps.redundant() and !base.redundant() and !night.redundant());

    // An uncontested record still has its one provider; a record nobody has, none. A
    // manifest is not in the report at all.
    try testing.expectEqualDeep(@as([]const u32, &.{0}), report.providers(ContentId.fromString("base:three")));
    try testing.expectEqualDeep(@as([]const u32, &.{1}), report.providers(ContentId.fromString("lamps:own")));
    try testing.expectEqual(@as(usize, 0), report.providers(ContentId.fromString("no:such")).len);
    try testing.expectEqual(@as(usize, 0), report.providers(ContentId.fromString("night:content")).len);
}

test "the player's order decides the winner, and shuffled discovery changes nothing" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();

    var found = try discover_mod.discover(testing.allocator, f.os, f.root, .{}, &f.diags);
    defer found.deinit();

    // Moving `lamps` last hands it `base:one`, and `old` after `night` hands it `base:two`:
    // `night` now loses both, and `old` is no longer redundant.
    var res = try f.resolveOrder(found.candidates, &.{ "night:content", "old:content", "lamps:content" });
    defer res.deinit();
    var report = try compute(testing.allocator, f.os, res.order, .{}, &f.diags);
    defer report.deinit();
    try testing.expectEqualStrings("lamps:content", res.order[report.contested[0].winner()].name);
    try testing.expectEqualStrings("old:content", res.order[report.contested[1].winner()].name);
    try testing.expect(!packageNamed(res, report, "old:content").redundant());
    try testing.expectEqual(@as(u32, 2), packageNamed(res, report, "night:content").loses);

    // The candidates in every rotation give the same report, byte for byte.
    const reference = try describe(testing.allocator, res, report);
    defer testing.allocator.free(reference);
    const shuffled = try testing.allocator.dupe(discover_mod.Candidate, found.candidates);
    defer testing.allocator.free(shuffled);
    for (0..shuffled.len) |_| {
        std.mem.rotate(discover_mod.Candidate, shuffled, 1);
        var again = try f.resolveOrder(shuffled, &.{ "night:content", "old:content", "lamps:content" });
        defer again.deinit();
        var again_report = try compute(testing.allocator, f.os, again.order, .{}, &f.diags);
        defer again_report.deinit();
        const text = try describe(testing.allocator, again, again_report);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(reference, text);
    }
}

test "a package that can no longer be read is a diagnostic and provides nothing" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();

    var found = try discover_mod.discover(testing.allocator, f.os, f.root, .{}, &f.diags);
    defer found.deinit();
    var res = try f.resolveOrder(found.candidates, &.{ "lamps:content", "night:content" });
    defer res.deinit();

    // Gone between discovery and the report, as a player deleting a file mid-session does.
    try f.tmp.dir.deleteFile(testing.io, "night.fpk");
    var report = try compute(testing.allocator, f.os, res.order, .{}, &f.diags);
    defer report.deinit();

    const night = packageNamed(res, report, "night:content");
    try testing.expect(!night.readable);
    try testing.expectEqual(@as(u32, 0), night.provides);
    try testing.expectEqual(@as(usize, 1), report.contested.len);
    try testing.expectEqualStrings("lamps:content", res.order[report.contested[0].winner()].name);
    try testing.expectEqual(@as(usize, 1), f.diags.count());
    try testing.expect(!f.diags.failed);
}

/// A report and the order it was computed over, as one string to compare.
fn describe(gpa: Allocator, res: resolve_mod.Resolution, report: Conflicts) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    for (res.order, report.packages) |entry, p| {
        try w.print("{s} provides {d} wins {d} loses {d} readable {}\n", .{ entry.name, p.provides, p.wins, p.loses, p.readable });
    }
    for (report.contested) |record| {
        try w.print("{s}:", .{record.name});
        for (record.providers) |p| try w.print(" {s}", .{res.order[p].name});
        try w.writeByte('\n');
    }
    return out.toOwnedSlice();
}
