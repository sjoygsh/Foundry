//! Dependency packages: the `.fpk` files a host grants a workspace or a compile.
//!
//! **A dependency is a capability, not a search.** Nothing here looks for a package. The
//! host names every `.fpk` a session may see, in the order it means them, and this module
//! turns that list into something a compile can be handed: the packages, their manifests,
//! and their schemas registered into the registry the authoring package is then checked
//! against. A package nobody named is not merely unreadable — it is unknown, and that is
//! what makes "missing or incompatible declared dependencies are diagnostics, not silently
//! supplied packages" a sentence the code can keep (`docs/design/editor.md` §4).
//!
//! **Two hosts, one rule.** An editor's workspace and `fpack`'s command line both arrive
//! here with a list of files and nothing else, so the packages a compile is checked against
//! are the same packages a session browses, read by the same code under the same bounds.
//!
//! Design: `docs/design/editor.md` §4; `docs/design/public-abi.md` §12 for what a package
//! is read under.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const mod = @import("mod");
const platform = @import("platform");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Diagnostics = data.Diagnostics;
const Os = platform.os.Os;

/// One dependency the host granted.
pub const Source = struct {
    /// The `.fpk` file, spelled by the host.
    ///
    /// **A capability, not content.** Nothing in a package can name another one, so this
    /// path cannot be steered by anything an author wrote; what it is subject to is the
    /// no-follow rule every other read in the authoring path keeps, which is applied to it
    /// in `load`.
    path: []const u8,
    /// Where this package's assets were installed, or null when it has none.
    ///
    /// Recorded rather than used: an asset is copied into a workspace's snapshot at a later
    /// step (`editor.md` §7), and the workspace is where the roots are kept until then.
    assets_root: ?[]const u8 = null,
};

pub const Limits = struct {
    /// One package file. The same bound as one source file, because a `.fpk` is compiled
    /// content and content is not a data dump (ADR-0006).
    max_package_bytes: usize = 16 * 1024 * 1024,
    /// All of them together, so that a hundred packages is a refusal rather than a slow
    /// open.
    max_total_bytes: usize = 64 * 1024 * 1024,
    /// How many a caller may hand over.
    ///
    /// Not a row of `editor.md` §4's table, which budgets what a workspace *keeps*. This
    /// bounds what it is asked to open, and a set larger than it is a mod library rather
    /// than one package's dependencies.
    max_packages: u32 = 64,
    /// The bounds a package's own structures are read under.
    content: data.Limits = .default,

    pub const default: Limits = .{};
};

pub const Error = error{
    /// At least one diagnostic of severity `error` was recorded.
    ContentInvalid,
    /// A package file could not be read. Not a content problem, and reported apart from
    /// one, as everywhere else in the pipeline.
    IoFailed,
    /// A configured limit was exceeded.
    OverBudget,
} || Allocator.Error;

/// One open dependency: its bytes, its manifest, and the reader over both.
pub const Package = struct {
    /// The path the host spelled, owned by the set.
    path: []const u8,
    /// The asset root the host paired with it, owned by the set.
    assets_root: ?[]const u8 = null,
    /// The package's bytes, owned by the set. `reader` borrows them for as long as the
    /// set lives, which is why a `Package` is never copied out of one.
    bytes: []u8,
    reader: data.fpk.Reader,
    /// What the package says it is, with its strings in the set's arena.
    manifest: mod.Manifest,

    pub fn id(self: *const Package) ContentId {
        return self.manifest.id;
    }

    /// The package's `namespace:name`, from its header — the spelling of `id`.
    pub fn name(self: *const Package) []const u8 {
        return self.manifest.id_name;
    }

    pub fn version(self: *const Package) u32 {
        return self.manifest.version;
    }
};

/// An ordered, read-only set of dependency packages.
///
/// **Order is the caller's and never the filesystem's** (I9). It is also the order the
/// packages are registered in, so a set built from the same list in the same order reads
/// the same on every machine.
pub const Set = struct {
    gpa: Allocator,
    arena: core.Arena,
    packages: std.ArrayList(Package) = .empty,
    limits: Limits = .default,

    pub fn init(gpa: Allocator) Set {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(self: *Set) void {
        for (self.packages.items) |*package| {
            package.reader.deinit();
            self.gpa.free(package.bytes);
        }
        self.packages.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const Set) u32 {
        return @intCast(self.packages.items.len);
    }

    pub fn items(self: *const Set) []const Package {
        return self.packages.items;
    }

    pub fn find(self: *const Set, id: ContentId) ?*const Package {
        for (self.packages.items) |*package| {
            if (package.manifest.id.eql(id)) return package;
        }
        return null;
    }

    /// The package whose spelling is `name`, which is how a diagnostic recovers a word for
    /// an id it only has as a hash (`mod.Manifest.Requirement`).
    pub fn findNamed(self: *const Set, name: []const u8) ?*const Package {
        for (self.packages.items) |*package| {
            if (std.mem.eql(u8, package.manifest.id_name, name)) return package;
        }
        return null;
    }

    /// The package the host spelled as `path`. A shortcut, so that a file named twice is not
    /// read twice; `findByBytes` is what makes the set a set under any spelling.
    pub fn findByPath(self: *const Set, path: []const u8) ?*const Package {
        for (self.packages.items) |*package| {
            if (std.mem.eql(u8, package.path, path)) return package;
        }
        return null;
    }

    /// The package whose file holds exactly `bytes`: the same file under another spelling
    /// of its path, or a copy of it, which is the same package again rather than a second.
    fn findByBytes(self: *const Set, bytes: []const u8) ?*const Package {
        for (self.packages.items) |*package| {
            if (std.mem.eql(u8, package.bytes, bytes)) return package;
        }
        return null;
    }

    /// The package satisfying `requirement`, or null if none does.
    pub fn satisfies(self: *const Set, requirement: mod.Requirement) ?*const Package {
        for (self.packages.items) |*package| {
            if (!package.manifest.id.eql(requirement.id)) continue;
            if (!requirement.range.accepts(package.manifest.version)) continue;
            return package;
        }
        return null;
    }

    /// Reads every package in `sources`, in order.
    ///
    /// **Every read is confined and follows no link.** A dependency path is a host
    /// capability — an operator wrote it on a command line — so its directory is the root
    /// the read is confined to and the file itself is the one component checked: a `.fpk`
    /// reached through a symlink is refused rather than followed, exactly as a source file
    /// inside a package is. What that buys is the property that matters: a package file
    /// cannot redirect a read somewhere the host did not name.
    pub fn load(
        gpa: Allocator,
        os: *Os,
        sources: []const Source,
        limits: Limits,
        diags: *Diagnostics,
    ) Error!Set {
        var self: Set = .{ .gpa = gpa, .arena = .init(gpa), .limits = limits };
        errdefer self.deinit();

        if (sources.len > limits.max_packages) {
            try diags.addFmt(gpa, .err, .whole("<dependencies>"), 1, "", "more than {d} dependency packages were granted; {d} were given", .{ limits.max_packages, sources.len });
            return error.OverBudget;
        }

        var total: usize = 0;
        for (sources) |source| {
            // The same file named twice is one dependency: a set is a set, and registering
            // one package's schemas twice would say nothing new. Only a shortcut past the
            // read — the byte comparison below is what holds under any spelling of a path.
            if (self.findByPath(source.path) != null) continue;

            // Split so that the confinement starts at the directory the host named. A path
            // with no directory component is relative to the working directory, which is
            // what `"."` says.
            const dir = std.fs.path.dirname(source.path) orelse ".";
            const leaf = std.fs.path.basename(source.path);
            const read = os.readFileConfined(gpa, dir, leaf, limits.max_package_bytes) catch |err| {
                try diags.addFmt(gpa, .err, .whole(source.path), 1, "", "could not be read as a dependency package: {s}", .{@errorName(err)});
                return error.IoFailed;
            };

            // A second spelling of a path already read, or a byte-identical copy of a
            // package, is the same package, and a set is a set.
            if (self.findByBytes(read.bytes) != null) {
                gpa.free(read.bytes);
                continue;
            }
            errdefer gpa.free(read.bytes);

            total += read.bytes.len;
            if (total > limits.max_total_bytes) {
                try diags.addFmt(gpa, .err, .whole(source.path), 1, "", "the dependency packages total more than {d} bytes", .{limits.max_total_bytes});
                return error.OverBudget;
            }

            var reader = data.fpk.Reader.open(gpa, read.bytes, limits.content) catch |err| {
                try diags.addFmt(gpa, .err, .whole(source.path), 1, "", "is not a usable content package: {s}", .{@errorName(err)});
                return error.ContentInvalid;
            };
            errdefer reader.deinit();

            // Every package describes itself (ADR-0027), so one that does not is a package
            // this build will not pretend to understand.
            const manifest = mod.manifest.read(self.arena.allocator(), &reader) catch |err| {
                try diags.addFmt(gpa, .err, .whole(source.path), 1, "", "has no manifest this build can read: {s}", .{@errorName(err)});
                return error.ContentInvalid;
            };

            // **Two different files that are one package is a grant that means two
            // things.** Which of them a record was checked against, and which one a
            // requirement was satisfied by, would be decided by the order they were named
            // in — a guess, where the host meant a grant. So it is refused, naming both.
            if (self.find(manifest.id)) |other| {
                try diags.addFmt(gpa, .err, .whole(source.path), 1, "", "is '{s}', and so is '{s}', which was granted first; a package is granted once", .{ manifest.id_name, other.path });
                return error.ContentInvalid;
            }

            try self.packages.append(gpa, .{
                .path = try self.arena.allocator().dupe(u8, source.path),
                .assets_root = if (source.assets_root) |root| try self.arena.allocator().dupe(u8, root) else null,
                .bytes = read.bytes,
                .reader = reader,
                .manifest = manifest,
            });
        }
        return self;
    }

    /// Registers every schema every package carries, in the set's order.
    ///
    /// **A dependency's schemas are what make its content referable.** An authored record
    /// naming `example:torch` is checked against the schema the package that declares it
    /// shipped, not against a local guess — so the set is registered *before* the authoring
    /// package's own declarations, and a local `@schema` that disagrees with a dependency's
    /// is reported against the local declaration, which is the one an author can change.
    ///
    /// Two packages declaring the same schema are held to `data`'s own rule for two
    /// declarations of it: the later one must be an additive change, or it is refused.
    pub fn registerSchemas(
        self: *const Set,
        gpa: Allocator,
        registry: *data.Registry,
        diags: *Diagnostics,
    ) Error!void {
        var failed = false;
        for (self.packages.items) |*package| {
            for (package.reader.schemas, package.reader.schema_names) |schema, name| {
                _ = registry.register(gpa, schema) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        failed = true;
                        try diags.addFmt(gpa, .err, .whole(package.path), 1, "", "schema '{s}' {s}", .{ name, data.schema.describeRegisterError(err) });
                    },
                };
            }
        }
        if (failed) return error.ContentInvalid;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");
const compiler = @import("compiler.zig");

const Fixture = struct {
    tmp: std.testing.TmpDir,
    os: *Os,
    root: []const u8,
    root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    out_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    /// Paths this fixture allocated, so that a test does not have to free them by hand.
    owned: std.ArrayList([]const u8) = .empty,

    fn init() !*Fixture {
        const gpa = testing.allocator;
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);
        self.* = .{
            .tmp = testing.tmpDir(.{}),
            .os = try Os.init(gpa, .{ .app_name = "foundry-author-test" }),
            .root = "",
        };
        const n = try self.tmp.dir.realPath(testing.io, &self.root_buf);
        self.root = self.root_buf[0..n];
        return self;
    }

    fn deinit(self: *Fixture) void {
        const gpa = testing.allocator;
        for (self.owned.items) |path| gpa.free(path);
        self.owned.deinit(gpa);
        self.os.deinit();
        self.tmp.cleanup();
        gpa.destroy(self);
    }

    /// An absolute path under the fixture, remembered so the test need not free it.
    fn own(self: *Fixture, path: []const u8) ![]const u8 {
        const gpa = testing.allocator;
        errdefer gpa.free(path);
        try self.owned.append(gpa, path);
        return path;
    }

    fn write(self: *Fixture, rel: []const u8, contents: []const u8) !void {
        const gpa = testing.allocator;
        const path = try platform.os.joinPath(gpa, &.{ self.root, rel });
        defer gpa.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.os.createDirPath(parent);
        try self.os.writeFile(path, contents);
    }

    /// Compiles a package directory and writes the `.fpk` beside it, which is what both a
    /// workspace's dependencies and `fpack`'s `--dependency` are.
    fn pack(self: *Fixture, name: []const u8, manifest: []const u8, source: []const u8) ![]const u8 {
        const gpa = testing.allocator;
        const dir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.root, name });
        defer gpa.free(dir);
        const text = try std.fmt.allocPrint(gpa, "{s}\n{s}\n", .{ manifest, source });
        defer gpa.free(text);
        const text_path = try std.fmt.allocPrint(gpa, "{s}/mod.fdt", .{name});
        defer gpa.free(text_path);
        try self.write(text_path, text);

        var registry = data.Registry.init(gpa, .default);
        defer registry.deinit(gpa);
        var diags = Diagnostics.init(gpa, .default);
        defer diags.deinit(gpa);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);

        const identity = try compiler.compile(gpa, self.os, dir, .{}, &registry, &diags, &bytes);
        defer gpa.free(identity.name);
        if (diags.failed) {
            for (diags.items.items) |d| std.debug.print("fixture: {s}\n", .{d.message});
            return error.FixtureFailed;
        }

        const path = try std.fmt.allocPrint(gpa, "{s}/{s}.fpk", .{ self.root, name });
        try self.os.writeFile(path, bytes.items);
        return self.own(path);
    }
};

test "a set is read in the order it was given, and each package knows itself" {
    const f = try Fixture.init();
    defer f.deinit();

    const first = try f.pack("alpha", "foundry:mod demo:alpha { name \"Alpha\" version 3 license \"MIT\" }", "");
    const second = try f.pack("beta", "foundry:mod demo:beta { name \"Beta\" version 1 license \"MIT\" }", "");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var set = try Set.load(gpa, f.os, &.{
        .{ .path = first, .assets_root = "/opt/demo/alpha" },
        .{ .path = second },
    }, .{}, &diags);
    defer set.deinit();

    try testing.expectEqual(@as(u32, 2), set.count());
    try testing.expectEqualStrings("demo:alpha", set.items()[0].name());
    try testing.expectEqual(@as(u32, 3), set.items()[0].version());
    try testing.expectEqualStrings("/opt/demo/alpha", set.items()[0].assets_root.?);
    try testing.expect(set.items()[1].assets_root == null);
    try testing.expect(set.find(core.ContentId.fromString("demo:beta")) != null);
    try testing.expect(set.findNamed("demo:nothing") == null);
    try testing.expect(!diags.failed);
}

test "the same package named twice is one dependency" {
    const f = try Fixture.init();
    defer f.deinit();

    const path = try f.pack("alpha", "foundry:mod demo:alpha { name \"Alpha\" version 1 license \"MIT\" }", "");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    // A host walking requirements transitively names a package more than once, and a set is
    // a set: the second naming adds nothing and registers no schema a second time.
    var set = try Set.load(gpa, f.os, &.{ .{ .path = path }, .{ .path = path } }, .{}, &diags);
    defer set.deinit();

    try testing.expectEqual(@as(u32, 1), set.count());
    try testing.expectEqualStrings("demo:alpha", set.items()[0].name());
    try testing.expect(!diags.failed);
}

test "a requirement is satisfied only by the package that declares it, at a version it accepts" {
    const f = try Fixture.init();
    defer f.deinit();

    const path = try f.pack("alpha", "foundry:mod demo:alpha { name \"Alpha\" version 3 license \"MIT\" }", "");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var set = try Set.load(gpa, f.os, &.{.{ .path = path }}, .{}, &diags);
    defer set.deinit();

    const alpha = core.ContentId.fromString("demo:alpha");
    try testing.expect(set.satisfies(.{ .id = alpha }) != null);
    try testing.expect(set.satisfies(.{ .id = alpha, .range = .{ .min = 1, .max = 3 } }) != null);
    try testing.expect(set.satisfies(.{ .id = alpha, .range = .{ .min = 4 } }) == null);
    try testing.expect(set.satisfies(.{ .id = alpha, .range = .{ .min = 1, .max = 2 } }) == null);
    try testing.expect(set.satisfies(.{ .id = core.ContentId.fromString("demo:missing") }) == null);
}

test "a file that is not a package is refused, and the refusal names it" {
    const f = try Fixture.init();
    defer f.deinit();
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/notes.fpk", .{f.root});
    defer testing.allocator.free(path);
    try f.write("notes.fpk", "not a package at all");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    try testing.expectError(error.ContentInvalid, Set.load(gpa, f.os, &.{.{ .path = path }}, .{}, &diags));
    try testing.expect(diags.failed);
    try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "not a usable content package") != null);
}

test "a package with no manifest is refused" {
    const f = try Fixture.init();
    defer f.deinit();
    const gpa = testing.allocator;

    // A real `.fpk` of a kind this build will not accept as a dependency: it opens as a
    // package and carries no `foundry:mod`, which is what a hand-built file looks like.
    // Written by `data` directly, because the compiler will not write one.
    var pkg = try data.Package.init(gpa, "demo:bare", 1, .default);
    defer pkg.deinit(gpa);
    var registry = data.Registry.init(gpa, .default);
    defer registry.deinit(gpa);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try data.fpk.write(gpa, &pkg, &registry, &bytes);
    try f.write("bare.fpk", bytes.items);
    const path = try f.own(try std.fmt.allocPrint(gpa, "{s}/bare.fpk", .{f.root}));

    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);
    try testing.expectError(error.ContentInvalid, Set.load(gpa, f.os, &.{.{ .path = path }}, .{}, &diags));
    try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "has no manifest this build can read: NoManifest") != null);
}

test "a truncated package is refused before its manifest is looked for" {
    const f = try Fixture.init();
    defer f.deinit();

    const path = try f.pack("alpha", "foundry:mod demo:alpha { name \"Alpha\" version 1 license \"MIT\" }", "");
    const bytes = try f.os.readFile(testing.allocator, path, 1 << 20);
    defer testing.allocator.free(bytes);

    // Truncated rather than re-written: the manifest lives in the record section, so a
    // file whose records are gone cannot even be opened as a package.
    const half = bytes[0 .. bytes.len / 2];
    const truncated = try std.fmt.allocPrint(testing.allocator, "{s}/truncated.fpk", .{f.root});
    defer testing.allocator.free(truncated);
    try f.os.writeFile(truncated, half);

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);
    try testing.expectError(error.ContentInvalid, Set.load(gpa, f.os, &.{.{ .path = truncated }}, .{}, &diags));
    try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "is not a usable content package") != null);
}

test "a copy of a package is the same package, and a different file claiming it is refused" {
    const f = try Fixture.init();
    defer f.deinit();
    const gpa = testing.allocator;

    const original = try f.pack("alpha", "foundry:mod demo:alpha { name \"Alpha\" version 1 license \"MIT\" }", "");
    const bytes = try f.os.readFile(gpa, original, 1 << 20);
    defer gpa.free(bytes);
    try f.write("copy.fpk", bytes);
    const copy = try f.own(try std.fmt.allocPrint(gpa, "{s}/copy.fpk", .{f.root}));

    // The same bytes under another name, which is also what a second spelling of one
    // path reads as: one package, and nothing to report.
    {
        var diags = Diagnostics.init(gpa, .default);
        defer diags.deinit(gpa);
        var set = try Set.load(gpa, f.os, &.{ .{ .path = original }, .{ .path = copy } }, .{}, &diags);
        defer set.deinit();
        try testing.expectEqual(@as(u32, 1), set.count());
        try testing.expect(!diags.failed);
    }

    // The same package id in a different file — here, a later version — is a grant that
    // would mean whichever was named first. Refused, naming both.
    const newer = try f.pack("alpha2", "foundry:mod demo:alpha { name \"Alpha\" version 2 license \"MIT\" }", "");
    {
        var diags = Diagnostics.init(gpa, .default);
        defer diags.deinit(gpa);
        try testing.expectError(error.ContentInvalid, Set.load(gpa, f.os, &.{ .{ .path = original }, .{ .path = newer } }, .{}, &diags));
        const message = diags.items.items[0].message;
        try testing.expect(std.mem.indexOf(u8, message, "is 'demo:alpha', and so is") != null);
        try testing.expect(std.mem.indexOf(u8, message, "alpha.fpk") != null);
        try testing.expect(std.mem.indexOf(u8, diags.items.items[0].location.file, "alpha2.fpk") != null);
    }
}

test "a dependency reached through a symlink is refused rather than followed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const f = try Fixture.init();
    defer f.deinit();

    const path = try f.pack("alpha", "foundry:mod demo:alpha { name \"Alpha\" version 1 license \"MIT\" }", "");
    try f.tmp.dir.symLink(testing.io, path, "linked.fpk", .{});
    const link = try f.own(try std.fmt.allocPrint(testing.allocator, "{s}/linked.fpk", .{f.root}));

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    try testing.expectError(error.IoFailed, Set.load(gpa, f.os, &.{.{ .path = link }}, .{}, &diags));
    try testing.expect(diags.failed);
}

test "more packages than the limit allows is refused before any is read" {
    const f = try Fixture.init();
    defer f.deinit();
    const path = try f.pack("alpha", "foundry:mod demo:alpha { name \"Alpha\" version 1 license \"MIT\" }", "");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    try testing.expectError(error.OverBudget, Set.load(gpa, f.os, &.{
        .{ .path = path },
        .{ .path = path },
    }, .{ .max_packages = 1 }, &diags));
    try testing.expect(diags.failed);
    try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "more than 1 dependency packages") != null);
}

test "a package larger than the per-file bound is refused" {
    const f = try Fixture.init();
    defer f.deinit();
    const path = try f.pack("alpha", "foundry:mod demo:alpha { name \"Alpha\" version 1 license \"MIT\" }", "");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    try testing.expectError(error.IoFailed, Set.load(gpa, f.os, &.{.{ .path = path }}, .{ .max_package_bytes = 16 }, &diags));
    try testing.expect(diags.failed);
}

test "a dependency's schemas are registered, and the set can be handed to a compile" {
    const f = try Fixture.init();
    defer f.deinit();

    const path = try f.pack(
        "alpha",
        "foundry:mod demo:alpha { name \"Alpha\" version 1 license \"MIT\" }",
        "@schema demo:torch { kind string lit bool }",
    );

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);
    var registry = data.Registry.init(gpa, .default);
    defer registry.deinit(gpa);

    var set = try Set.load(gpa, f.os, &.{.{ .path = path }}, .{}, &diags);
    defer set.deinit();
    try set.registerSchemas(gpa, &registry, &diags);

    try testing.expect(!diags.failed);
    try testing.expect(registry.lookup(.fromStringUnchecked("demo:torch")) != null);
}

test "two dependencies disagreeing about one schema is refused, and the second is named" {
    const f = try Fixture.init();
    defer f.deinit();

    const first = try f.pack(
        "alpha",
        "foundry:mod demo:alpha { name \"Alpha\" version 1 license \"MIT\" }",
        "@schema demo:torch { kind string }",
    );
    const second = try f.pack(
        "beta",
        "foundry:mod demo:beta { name \"Beta\" version 1 license \"MIT\" }",
        "@schema demo:torch { kind u32 }",
    );

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);
    var registry = data.Registry.init(gpa, .default);
    defer registry.deinit(gpa);

    var set = try Set.load(gpa, f.os, &.{ .{ .path = first }, .{ .path = second } }, .{}, &diags);
    defer set.deinit();

    try testing.expectError(error.ContentInvalid, set.registerSchemas(gpa, &registry, &diags));
    try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "demo:torch") != null);
    try testing.expect(std.mem.indexOf(u8, diags.items.items[0].location.file, "beta.fpk") != null);
}
