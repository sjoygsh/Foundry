//! A workspace: one granted package directory, open for authoring.
//!
//! **What a session holds while an author works on a package**: the source documents it
//! found, the dependency packages its host granted, what its manifest says it is and needs,
//! and the bounds all of that was read under. Nothing here edits, saves or compiles — a
//! workspace is the state an editor's later steps change, and this step is what makes that
//! state exist and refuse to exist when it should not (`docs/design/editor.md` §4 and §5).
//!
//! **A workspace is a capability, and its root is borrowed.** The host owns the directory
//! and grants it; nothing in a package can name another one, and no call here reaches a
//! path outside what it was given. Reads go through `platform`'s confined, no-follow
//! primitives, which refuse a link rather than follow it at every component of a path — so
//! a source reached through a symlink is not read, and a granted directory cannot be used
//! to read the files beside it.
//!
//! **Refuses before it keeps.** Every bound is enforced as the thing it bounds is taken: a
//! tree with more sources than the walk allows, a source larger than one file may be, or a
//! total larger than a workspace may hold is `error.OverBudget` with a diagnostic naming
//! the limit, and what it would have built is freed on the way out rather than returned
//! half-built. The same is true of a dependency that is not a package.
//!
//! **What is a diagnostic rather than a refusal is deliberate.** An empty directory opens,
//! because that is where a new package starts; a manifest that is not a manifest opens with
//! the diagnostic recorded and no identity, because the file that needs fixing must be
//! reachable by the tool that fixes it (§5, "an externally malformed document remains
//! byte-preserved and diagnostic/read-only"); and a requirement no granted package provides
//! is a diagnostic beside a workspace that still opens, because a missing dependency is
//! something the author is about to write down, not a reason to show them nothing.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");

const compiler = @import("compiler.zig");
const dependency = @import("dependency.zig");

const Allocator = std.mem.Allocator;
const Diagnostics = data.Diagnostics;
const Os = platform.os.Os;

/// How much of a workspace a session will hold.
///
/// `editor.md` §4's table, where each row is this module's to keep: one source file, all
/// the source files together, and the walk that finds them. The rows that belong to another
/// module are that module's limits, named here so a host configures one object: the parser's
/// `data.Limits` and the dependency reader's own bounds.
///
/// **A host may configure tighter bounds and this never raises one.** A limit silently
/// raised is a limit that is not one, and §4 is explicit that the configured values are
/// reported rather than adjusted. They are public for exactly that reason: a later step
/// publishes them through workspace info.
pub const Limits = struct {
    /// One source file. The same number `compiler.Options` defaults to, because a source
    /// file is one source file whichever way it is read.
    max_source_bytes: usize = 16 * 1024 * 1024,
    /// Every source file together.
    max_total_source_bytes: usize = 64 * 1024 * 1024,
    /// How much of the granted directory discovery may look at.
    walk: compiler.Walk.Limits = .default,
    /// The bounds a document is parsed under — nesting, fields, list lengths, identifier
    /// lengths (`data.Limits`), and the diagnostic cap a workspace operation reports under.
    content: data.Limits = .default,
    /// What the granted dependency packages are read under.
    dependencies: dependency.Limits = .default,

    pub const default: Limits = .{};
};

/// What a host grants a workspace, besides the directory itself.
pub const Options = struct {
    /// The `.fpk` files this package is written against, in the order the host means them.
    ///
    /// **Explicit, and never discovered** (§4). The engine does not search for a package: a
    /// dependency nobody granted is unknown rather than found, so a workspace reads the
    /// same set on two machines with the same grant and no ambient mod library can change
    /// what an author is checked against.
    dependencies: []const dependency.Source = &.{},
    limits: Limits = .default,
};

pub const Error = error{
    /// A granted file is not a package, or is a package this build cannot read.
    ContentInvalid,
    /// Something could not be read. Not a content problem, and reported apart from one.
    IoFailed,
    /// A configured limit was exceeded. Nothing about the content is wrong — there is too
    /// much of it to look at — and the difference decides whether an author edits a file or
    /// moves a tree.
    OverBudget,
} || Allocator.Error;

/// One source file, open in a workspace.
pub const Document = struct {
    /// The package-relative path, with `/` on every platform, owned by the workspace's
    /// arena.
    path: []const u8,
    /// The document's current bytes, owned by the workspace.
    ///
    /// **Current and baseline are the same bytes at open**, which is all this step can
    /// have: nothing edits yet, so there is nothing for a baseline to differ from, and §6's
    /// dirty comparison is these bytes against themselves until the step that adds edits
    /// puts a second set beside them.
    bytes: []const u8,
    /// What the disk said when those bytes were read: size, kind, execute bit and
    /// modification time.
    ///
    /// Kept so that a refresh (§7) can ask its first question — "did this change under us?"
    /// — cheaply, and it is a fact to compare with a fresh stat rather than an answer on its
    /// own, because §7 is explicit that a modification time is not equality.
    disk: platform.os.FileInfo,
};

/// A granted package directory, open for authoring.
pub const Workspace = struct {
    gpa: Allocator,
    /// Everything owned that outlives one call: discovered paths and requirement names. The
    /// documents' bytes are not here, because each one is freed by name as it is replaced.
    arena: core.Arena,
    os: *Os,
    /// The granted directory, **borrowed**: the host owns it and this does not copy it, as
    /// a compile borrows the directory it is handed.
    root: []const u8,
    limits: Limits,
    /// Every source file, in discovery order — sorted by path, so the same tree gives the
    /// same list on every machine (I9).
    documents: []const Document = &.{},
    /// The granted dependency packages, read and checked. Empty is a valid set: a package
    /// with no dependencies has none.
    dependencies: dependency.Set,
    /// What the manifest says this package is, or null when there is no readable manifest.
    ///
    /// **Null is a state, not a failure** (§4): a directory with no manifest is where a new
    /// package starts, and one whose manifest is malformed opens with its diagnostic
    /// recorded so that the file needing the fix is the one the author can reach.
    identity: ?compiler.Identity = null,
    /// What the manifest says must load before this package, in declaration order.
    requires: []const compiler.SourceRequirement = &.{},

    /// Opens `root`: reads the manifest, loads the granted dependencies, discovers the
    /// sources and reads every one, and reports what the manifest requires that was not
    /// granted.
    pub fn open(
        gpa: Allocator,
        os: *Os,
        root: []const u8,
        options: Options,
        diags: *Diagnostics,
    ) Error!Workspace {
        var self: Workspace = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .os = os,
            .root = root,
            .limits = options.limits,
            .dependencies = .init(gpa),
        };
        errdefer self.deinit();

        try self.readManifest(diags);
        self.dependencies = try dependency.Set.load(gpa, os, options.dependencies, options.limits.dependencies, diags);
        try self.readDocuments(diags);
        try self.reportUnsatisfied(diags);

        return self;
    }

    pub fn deinit(self: *Workspace) void {
        for (self.documents) |document| self.gpa.free(document.bytes);
        self.gpa.free(self.documents);
        if (self.identity) |identity| self.gpa.free(identity.name);
        self.dependencies.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Reads `mod.fdt` if it is there, and takes the package's identity and requirements.
    fn readManifest(self: *Workspace, diags: *Diagnostics) Error!void {
        // **Asked before it is read**, because `readSelf` — which a *compile* uses, and
        // which is right to insist — makes an absent manifest a diagnostic, while an empty
        // directory is a valid workspace. It is one stat, and it is confined like every
        // other read here, so a link is refused rather than followed by it too.
        _ = self.os.statFileConfined(self.root, compiler.manifest_file) catch |err| switch (err) {
            error.FileNotFound => return,
            error.OutOfMemory => return error.OutOfMemory,
            // There, and not readable as a file: `readSelf` says so in its own words.
            else => {},
        };

        const self_read = compiler.readSelf(self.gpa, self.arena.allocator(), self.os, self.root, .{
            .limits = self.limits.content,
            .max_source_bytes = self.limits.max_source_bytes,
            .walk = self.limits.walk,
        }, diags) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Opened anyway, with the diagnostic kept. §5's malformed document is
            // diagnostic and read-only rather than invisible, and a workspace that refused
            // to open would hide the file behind the tool that is supposed to fix it.
            error.ContentInvalid, error.IoFailed => return,
            error.OverBudget => return error.OverBudget,
        };
        self.identity = self_read.identity;
        self.requires = self_read.requires;
    }

    /// Discovers the package's sources and reads every one.
    fn readDocuments(self: *Workspace, diags: *Diagnostics) Error!void {
        // The walk owns its lists and its paths live in this workspace's arena, which is
        // what outlives it. Order is the walk's and never the filesystem's (I9).
        var walk = try compiler.Walk.run(self.gpa, self.arena.allocator(), self.os, self.root, self.limits.walk, diags);
        defer walk.deinit(self.gpa);

        const documents = try self.gpa.alloc(Document, walk.sources.items.len);
        errdefer self.gpa.free(documents);

        // Only what has been kept: the array is one allocation and the bytes are many, so
        // an error part-way through frees the files already read rather than all of them.
        var kept: usize = 0;
        errdefer for (documents[0..kept]) |document| self.gpa.free(document.bytes);

        var total: usize = 0;
        for (walk.sources.items) |path| {
            const read = self.os.readFileConfined(self.gpa, self.root, path, self.limits.max_source_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FileTooLarge => {
                    try diags.addFmt(self.gpa, .err, .whole(path), 1, "", "is larger than the {d} bytes one source file may be", .{self.limits.max_source_bytes});
                    return error.OverBudget;
                },
                else => {
                    // **Refused rather than followed**, which is what the read being
                    // confined means: a source reached through a link, a path that climbs,
                    // or something that is not a regular file cannot be read into a
                    // workspace, and saying which file and why is the whole message.
                    try diags.addFmt(self.gpa, .err, .whole(path), 1, "", "could not be read as a source file: {s}", .{@errorName(err)});
                    return error.IoFailed;
                },
            };

            total += read.bytes.len;
            if (total > self.limits.max_total_source_bytes) {
                // Freed before the message, so that a failed diagnostic allocation cannot
                // leak the bytes it was about to report on.
                self.gpa.free(read.bytes);
                try diags.addFmt(self.gpa, .err, .whole(path), 1, "", "leaves the workspace's sources totalling more than {d} bytes", .{self.limits.max_total_source_bytes});
                return error.OverBudget;
            }

            documents[kept] = .{ .path = path, .bytes = read.bytes, .disk = read.info };
            kept += 1;
        }

        self.documents = documents;
    }

    /// Reports every declared requirement the granted set does not satisfy.
    ///
    /// **A diagnostic, not a refusal** (§4), at severity `error` so that a host which checks
    /// `diags.failed` sees a package that cannot build yet. Naming the version the author
    /// wrote and the version they were granted is the one case where this can say what to
    /// change; naming the package they must ask their host for is the other.
    fn reportUnsatisfied(self: *const Workspace, diags: *Diagnostics) Error!void {
        for (self.requires) |required| {
            if (self.dependencies.satisfies(required.requirement) != null) continue;

            const range = required.requirement.range;
            const origin = required.origin;
            if (self.dependencies.find(required.requirement.id)) |granted| {
                if (range.max) |max| {
                    try diags.addFmt(self.gpa, .err, origin.location(), origin.length, origin.line_text, "'requires' names '{s}' at version {d} to {d}, and the granted package is version {d}", .{ required.name, range.min, max, granted.version() });
                } else {
                    try diags.addFmt(self.gpa, .err, origin.location(), origin.length, origin.line_text, "'requires' names '{s}' at version {d} or later, and the granted package is version {d}", .{ required.name, range.min, granted.version() });
                }
                continue;
            }

            try diags.addFmt(self.gpa, .err, origin.location(), origin.length, origin.line_text, "'requires' names '{s}', which no granted dependency provides: a dependency is named by the host, never found by the engine", .{required.name});
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");

const Fixture = struct {
    tmp: std.testing.TmpDir,
    os: *Os,
    root: []const u8,
    root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
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
    fn at(self: *Fixture, rel: []const u8) ![]const u8 {
        const gpa = testing.allocator;
        const path = try platform.os.joinPath(gpa, &.{ self.root, rel });
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

    /// The manifest of the package under test, which is always `pkg/mod.fdt`: a workspace's
    /// root is one directory, and a test that wrote its manifest at the fixture's root
    /// would be granting a directory it did not mean to.
    fn manifest(self: *Fixture, text: []const u8) !void {
        try self.write("pkg/mod.fdt", text);
    }

    /// Compiles a dependency package and writes the `.fpk` beside it, which is what a
    /// granted dependency file is.
    fn pack(self: *Fixture, name: []const u8, manifest_text: []const u8, source: []const u8) ![]const u8 {
        const gpa = testing.allocator;
        const dir = try std.fmt.allocPrint(gpa, "{s}/deps/{s}", .{ self.root, name });
        defer gpa.free(dir);
        const text = try std.fmt.allocPrint(gpa, "{s}\n{s}\n", .{ manifest_text, source });
        defer gpa.free(text);
        const text_path = try std.fmt.allocPrint(gpa, "deps/{s}/mod.fdt", .{name});
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

        const rel = try std.fmt.allocPrint(gpa, "deps/{s}.fpk", .{name});
        defer gpa.free(rel);
        const path = try self.at(rel);
        try self.os.writeFile(path, bytes.items);
        return path;
    }
};

test "sources are discovered in path order, and the manifest is one of them" {
    const f = try Fixture.init();
    defer f.deinit();

    // Written in the order a filesystem is free to return them in, and one of them nested,
    // so that a walk which kept the listing's order or walked breadth-first would fail here.
    try f.write("pkg/z/last.fdt", "foundry:thing demo:last { }\n");
    try f.write("pkg/b.fdt", "foundry:thing demo:b { }\n");
    try f.write("pkg/a.fdt", "foundry:thing demo:a { }\n");
    try f.write("pkg/notes.txt", "not content\n");
    try f.write("pkg/.hidden/ignored.fdt", "foundry:thing demo:hidden { }\n");
    try f.manifest("foundry:mod demo:root { name \"Root\" version 1 license \"MIT\" }\n");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{}, &diags);
    defer workspace.deinit();

    try testing.expectEqual(@as(usize, 4), workspace.documents.len);
    try testing.expectEqualStrings("a.fdt", workspace.documents[0].path);
    try testing.expectEqualStrings("b.fdt", workspace.documents[1].path);
    try testing.expectEqualStrings("mod.fdt", workspace.documents[2].path);
    try testing.expectEqualStrings("z/last.fdt", workspace.documents[3].path);
    try testing.expectEqualStrings("foundry:thing demo:a { }\n", workspace.documents[0].bytes);

    // The baseline is the same read that produced the bytes, not a second stat of a file
    // that may have changed in between.
    try testing.expectEqual(@as(u64, workspace.documents[0].bytes.len), workspace.documents[0].disk.size);
    try testing.expect(workspace.documents[0].disk.modified_ns != 0);

    try testing.expectEqualStrings("demo:root", workspace.identity.?.name);
    try testing.expectEqual(@as(u32, 1), workspace.identity.?.version);
    try testing.expectEqual(@as(usize, 0), workspace.requires.len);
    try testing.expectEqual(@as(u32, 0), workspace.dependencies.count());
    try testing.expect(!diags.failed);
}

test "an empty directory is a workspace with nothing in it, not a failure" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.os.createDirPath(try f.at("pkg"));

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{}, &diags);
    defer workspace.deinit();

    // §4: this is where a new package starts, and a session that refused to open it could
    // not offer to create the manifest that would make it one.
    try testing.expectEqual(@as(usize, 0), workspace.documents.len);
    try testing.expect(workspace.identity == null);
    try testing.expectEqual(@as(usize, 0), workspace.requires.len);
    try testing.expect(!diags.failed);
}

test "a manifest gives the workspace its identity and its requirements" {
    const f = try Fixture.init();
    defer f.deinit();

    try f.manifest(
        \\foundry:mod demo:root {
        \\  name "Root" version 1 license "MIT"
        \\  requires [ { id demo:core min 2 max 4 } { id demo:torch } ]
        \\}
        \\
    );

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{
        .dependencies = &.{
            .{ .path = try f.pack("core", "foundry:mod demo:core { name \"Core\" version 3 license \"MIT\" }", "") },
            .{ .path = try f.pack("torch", "foundry:mod demo:torch { name \"Torch\" version 1 license \"MIT\" }", "") },
        },
    }, &diags);
    defer workspace.deinit();

    try testing.expectEqualStrings("demo:root", workspace.identity.?.name);
    try testing.expectEqual(@as(u32, 2), workspace.dependencies.count());

    try testing.expectEqual(@as(usize, 2), workspace.requires.len);
    try testing.expectEqualStrings("demo:core", workspace.requires[0].name);
    try testing.expectEqual(core.ContentId.fromString("demo:core"), workspace.requires[0].requirement.id);
    try testing.expectEqual(@as(u32, 2), workspace.requires[0].requirement.range.min);
    try testing.expectEqual(@as(?u32, 4), workspace.requires[0].requirement.range.max);
    // A requirement that leaves `min` out means any version, exactly as it does in a
    // compiled package, where the schema's own default supplies the 1.
    try testing.expectEqualStrings("demo:torch", workspace.requires[1].name);
    try testing.expectEqual(@as(u32, 1), workspace.requires[1].requirement.range.min);
    try testing.expectEqual(@as(?u32, null), workspace.requires[1].requirement.range.max);

    // The origin is the field an author wrote, so a caller's message points at the line
    // rather than at the file.
    try testing.expectEqualStrings("mod.fdt", workspace.requires[0].origin.file);
    try testing.expectEqual(@as(u32, 3), workspace.requires[0].origin.line);
    try testing.expectEqual(@as(u32, 8), workspace.requires[0].origin.length);
    try testing.expect(!diags.failed);
}

test "a requirement nothing granted provides is reported, and the workspace still opens" {
    const f = try Fixture.init();
    defer f.deinit();

    try f.write("pkg/a.fdt", "foundry:thing demo:a { }\n");
    try f.manifest("foundry:mod demo:root { name \"Root\" version 1 license \"MIT\" requires [ { id demo:core } ] }\n");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{}, &diags);
    defer workspace.deinit();

    // The point of the diagnostic rather than a refusal: the author can still see every
    // document, including the manifest they are about to add the dependency to.
    try testing.expectEqual(@as(usize, 2), workspace.documents.len);
    try testing.expect(diags.failed);
    try testing.expectEqual(@as(usize, 1), diags.items.items.len);
    try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "demo:core") != null);
    try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "never found by the engine") != null);
    try testing.expectEqualStrings("mod.fdt", diags.items.items[0].location.file);
}

test "a requirement the granted package is too old for names both versions" {
    const f = try Fixture.init();
    defer f.deinit();

    try f.manifest(
        \\foundry:mod demo:root {
        \\  name "Root" version 1 license "MIT"
        \\  requires [ { id demo:core min 5 } { id demo:core min 1 max 2 } ]
        \\}
        \\
    );

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{
        .dependencies = &.{.{ .path = try f.pack("core", "foundry:mod demo:core { name \"Core\" version 3 license \"MIT\" }", "") }},
    }, &diags);
    defer workspace.deinit();

    try testing.expect(diags.failed);
    try testing.expectEqual(@as(usize, 2), diags.items.items.len);
    try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "at version 5 or later, and the granted package is version 3") != null);
    try testing.expect(std.mem.indexOf(u8, diags.items.items[1].message, "at version 1 to 2, and the granted package is version 3") != null);
    // A satisfied requirement is not reported, so the workspace's own dependency on the
    // package it was granted is silent.
    try testing.expect(std.mem.indexOf(u8, diags.items.items[1].message, "demo:torch") == null);
}

test "a workspace's configured budgets refuse rather than truncate" {
    const gpa = testing.allocator;

    // More sources than the walk allows.
    {
        const f = try Fixture.init();
        defer f.deinit();
        try f.write("pkg/a.fdt", "foundry:thing demo:a { }\n");
        try f.write("pkg/b.fdt", "foundry:thing demo:b { }\n");
        try f.write("pkg/c.fdt", "foundry:thing demo:c { }\n");

        var diags = Diagnostics.init(gpa, .default);
        defer diags.deinit(gpa);

        try testing.expectError(error.OverBudget, Workspace.open(gpa, f.os, try f.at("pkg"), .{
            .limits = .{ .walk = .{ .max_sources = 2 } },
        }, &diags));
        try testing.expect(diags.failed);
        try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "one source file more than the 2 a package may contain") != null);
    }

    // One file larger than a source file may be.
    {
        const f = try Fixture.init();
        defer f.deinit();
        try f.write("pkg/a.fdt", "foundry:thing demo:a { }\n");

        var diags = Diagnostics.init(gpa, .default);
        defer diags.deinit(gpa);

        try testing.expectError(error.OverBudget, Workspace.open(gpa, f.os, try f.at("pkg"), .{
            .limits = .{ .max_source_bytes = 8 },
        }, &diags));
        try testing.expect(diags.failed);
        try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "larger than the 8 bytes") != null);
    }

    // Every source together larger than a workspace may hold, which the per-file bound
    // above does not catch: two files, each well inside it.
    {
        const f = try Fixture.init();
        defer f.deinit();
        try f.write("pkg/a.fdt", "foundry:thing demo:a { }\n");
        try f.write("pkg/b.fdt", "foundry:thing demo:b { }\n");

        var diags = Diagnostics.init(gpa, .default);
        defer diags.deinit(gpa);

        try testing.expectError(error.OverBudget, Workspace.open(gpa, f.os, try f.at("pkg"), .{
            .limits = .{ .max_total_source_bytes = 30 },
        }, &diags));
        try testing.expect(diags.failed);
        try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "totalling more than 30 bytes") != null);
    }

    // More entries than the walk may look at, none of them sources: the sources bound
    // alone would walk a tree of anything else without end.
    {
        const f = try Fixture.init();
        defer f.deinit();
        try f.write("pkg/a.txt", "");
        try f.write("pkg/b.txt", "");
        try f.write("pkg/c.txt", "");

        var diags = Diagnostics.init(gpa, .default);
        defer diags.deinit(gpa);

        try testing.expectError(error.OverBudget, Workspace.open(gpa, f.os, try f.at("pkg"), .{
            .limits = .{ .walk = .{ .max_entries = 2 } },
        }, &diags));
        try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "more than 2 entries") != null);
        // Named by where it is in the package, not by where the host keeps the package.
        try testing.expectEqualStrings(".", diags.items.items[0].location.file);
    }

    // A source deeper than the walk may descend.
    {
        const f = try Fixture.init();
        defer f.deinit();
        try f.write("pkg/one/two/three/deep.fdt", "foundry:thing demo:deep { }\n");

        var diags = Diagnostics.init(gpa, .default);
        defer diags.deinit(gpa);

        try testing.expectError(error.OverBudget, Workspace.open(gpa, f.os, try f.at("pkg"), .{
            .limits = .{ .walk = .{ .max_depth = 2 } },
        }, &diags));
        try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "deeper than 2 directories") != null);
        try testing.expectEqualStrings("one/two/three", diags.items.items[0].location.file);
    }
}

test "a source reached through a symlink is not read, and a link out is not followed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const f = try Fixture.init();
    defer f.deinit();

    // The granted directory is `pkg`, and both of these point out of it: one file and one
    // directory, because a walk that followed either would be reading content the host did
    // not grant.
    try f.write("pkg/inside.fdt", "foundry:thing demo:inside { }\n");
    try f.write("outside.fdt", "foundry:thing demo:outside { }\n");
    try f.write("elsewhere/other.fdt", "foundry:thing demo:other { }\n");
    try f.tmp.dir.symLink(testing.io, try f.at("outside.fdt"), "pkg/linked.fdt", .{});
    try f.tmp.dir.symLink(testing.io, try f.at("elsewhere"), "pkg/linked_dir", .{ .is_directory = true });

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{}, &diags);
    defer workspace.deinit();

    // One document, and it is the one that is really there. A link is skipped exactly as
    // the compiler skips it, so the editor's file list and `fpack`'s source list are the
    // same list rather than two answers to one question.
    try testing.expectEqual(@as(usize, 1), workspace.documents.len);
    try testing.expectEqualStrings("inside.fdt", workspace.documents[0].path);
    try testing.expect(!diags.failed);
}

test "a malformed manifest opens, keeps its diagnostic, and hides nothing else" {
    const f = try Fixture.init();
    defer f.deinit();

    const malformed = "this is not a manifest at all\n";
    try f.manifest(malformed);
    try f.write("pkg/a.fdt", "foundry:thing demo:a { }\n");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{}, &diags);
    defer workspace.deinit();

    try testing.expect(workspace.identity == null);
    try testing.expectEqual(@as(usize, 0), workspace.requires.len);
    try testing.expect(diags.failed);

    // §5: byte-preserved and diagnostic. The file is still a document, with the bytes the
    // author wrote in it, which is what makes the diagnostic's caret point at something.
    try testing.expectEqual(@as(usize, 2), workspace.documents.len);
    try testing.expectEqualStrings("a.fdt", workspace.documents[0].path);
    try testing.expectEqualStrings("mod.fdt", workspace.documents[1].path);
    try testing.expectEqualStrings("foundry:thing demo:a { }\n", workspace.documents[0].bytes);
    try testing.expectEqualStrings(malformed, workspace.documents[1].bytes);
}

test "a workspace's granted set is what a compile is handed" {
    const f = try Fixture.init();
    defer f.deinit();

    // A dependency that declares a schema, and a source in the workspace that uses it: the
    // record can only be checked if the granted package's schema reached the registry, and
    // the only path from one to the other is the set the workspace holds.
    const granted = try f.pack(
        "core",
        "foundry:mod demo:core { name \"Core\" version 1 license \"MIT\" }",
        "@schema demo:torch { kind string }",
    );
    try f.manifest("foundry:mod demo:root { name \"Root\" version 1 license \"MIT\" requires [ { id demo:core } ] }\n");
    try f.write("pkg/lamp.fdt", "demo:torch demo:lamp { kind \"torch\" }\n");

    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);

    var workspace = try Workspace.open(gpa, f.os, try f.at("pkg"), .{
        .dependencies = &.{.{ .path = granted }},
    }, &diags);
    defer workspace.deinit();
    try testing.expect(!diags.failed);

    var registry = data.Registry.init(gpa, .default);
    defer registry.deinit(gpa);
    try workspace.dependencies.registerSchemas(gpa, &registry, &diags);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    const identity = try compiler.compile(gpa, f.os, try f.at("pkg"), .{
        .dependencies = &workspace.dependencies,
    }, &registry, &diags, &bytes);
    defer gpa.free(identity.name);

    // Compiled, with the dependency's schema doing the checking: `demo:torch`'s `kind` is
    // a string and this record's value is one, so a set that had not been handed over
    // would have refused the record as an unknown schema instead.
    try testing.expect(!diags.failed);
    try testing.expectEqualStrings("demo:root", identity.name);
    try testing.expect(bytes.items.len > 0);
}
