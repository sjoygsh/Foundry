//! Compiling a package directory into a `.fpk`.
//!
//! Everything that is not argument parsing or writing to a terminal, so that the whole
//! compile is one call a test can make (`main.zig` is the shell around it).
//!
//! **`data` cannot open a file; this is the module that can.** The parser is handed bytes
//! and answers `@import` through a callback, and here is where that callback finally reads
//! a disk. Everything below `data` in the pipeline stays a pure function; the impurity is
//! collected in one place, on purpose.
//!
//! **Order is fixed everywhere it could vary** (I9). Directory listings are sorted, files
//! are parsed in that order, derived assets follow the same order, and a package therefore
//! compiles to the same bytes on any machine whose files are the same. A filesystem's own
//! enumeration order is not a specification and must never reach the output.
//!
//! Design: `docs/design/content-schemas.md` §6, `docs/design/assets.md` §3.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const scene = @import("scene");
const platform = @import("platform");

const Allocator = std.mem.Allocator;
const Diagnostics = data.Diagnostics;
const Document = data.Document;
const Limits = data.Limits;
const Location = data.diagnostic.Location;
const Os = platform.os.Os;
const Registry = data.Registry;

/// The extension a content source file has. Not configurable: a second spelling is a second
/// specification, and ADR-0020 named the format's extension once.
pub const source_extension = "fdt";

pub const Error = error{
    /// At least one diagnostic of severity `error` was recorded. The diagnostics are the
    /// result; this is the signal, as it is everywhere else in the pipeline.
    ContentInvalid,
    /// The package directory could not be read, or the output could not be written. Not a
    /// content problem, and reported separately from one.
    IoFailed,
} || Allocator.Error;

pub const Options = struct {
    /// The package's `namespace:name`. Supplied from outside rather than read from a
    /// manifest in the directory: `data` consumes a load order and does not compute one,
    /// and mod manifests are M7 (`content-schemas.md` §11). The namespace half also
    /// expands bare schema names in the package's own text.
    name: []const u8,
    version: u32 = 1,
    limits: Limits = .default,
    /// Cap on one source file, so a directory full of something else is refused rather
    /// than read.
    max_source_bytes: usize = 16 * 1024 * 1024,
};

/// Compiles the package rooted at `dir` and appends the `.fpk` bytes to `out`.
///
/// The four passes are separate because each one needs the whole of the one before:
/// every schema in the package must be registered before any record is checked, every
/// authored record must be checked before derivation can know which files are already
/// spoken for, and every record must exist before the writer can lay one out.
pub fn compile(
    gpa: Allocator,
    os: *Os,
    dir: []const u8,
    options: Options,
    registry: *Registry,
    diags: *Diagnostics,
    out: *std.ArrayList(u8),
) Error!void {
    var arena: core.Arena = .init(gpa);
    defer arena.deinit();

    var pkg = data.Package.init(gpa, options.name, options.version, options.limits) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diags.addFmt(gpa, .err, .whole(dir), 1, "", "'{s}' is not a valid package name: {s}", .{ options.name, @errorName(err) });
            return error.ContentInvalid;
        },
    };
    defer pkg.deinit(gpa);

    var walk = try Walk.run(gpa, arena.allocator(), os, dir, diags);
    defer walk.deinit(gpa);

    asset.schemas.registerAll(gpa, registry) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The engine's own schemas failing to register is a bug in the engine, not in the
        // package being compiled, and saying so is the only honest report.
        else => {
            try diags.addFmt(gpa, .err, .whole("<engine>"), 1, "", "the engine's asset schemas did not register: {s}", .{data.schema.describeRegisterError(err)});
            return error.ContentInvalid;
        },
    };

    // The tilemap record types. They live in `asset` rather than in `render2d` precisely so
    // that this line can exist: `fpack` has to check a map without linking a renderer
    // (`tilemaps-and-collision.md` §11).
    asset.tilemap.registerAll(gpa, registry) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diags.addFmt(gpa, .err, .whole("<engine>"), 1, "", "the engine's tilemap schemas did not register: {s}", .{data.schema.describeRegisterError(err)});
            return error.ContentInvalid;
        },
    };

    // `foundry:entity` and `foundry:scene`, for the same reason: an author describing a
    // scene must not have to declare an engine-owned record type themselves.
    scene.schemas.registerAll(gpa, registry) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diags.addFmt(gpa, .err, .whole("<engine>"), 1, "", "the engine's entity schemas did not register: {s}", .{data.schema.describeRegisterError(err)});
            return error.ContentInvalid;
        },
    };

    var loader: Loader = .{ .gpa = gpa, .arena = arena.allocator(), .os = os, .root = dir, .options = options };
    defer loader.deinit();

    var failed = false;

    // 1. Parse every source file, in sorted order.
    var docs: std.ArrayList(Document) = .empty;
    defer {
        for (docs.items) |*doc| doc.deinit(gpa);
        docs.deinit(gpa);
    }
    for (walk.sources.items) |rel| {
        const bytes = loader.read(rel) catch |err| {
            failed = true;
            try diags.addFmt(gpa, .err, .whole(rel), 1, "", "could not be read: {s}", .{@errorName(err)});
            continue;
        };
        var doc = data.parser.parse(gpa, rel, bytes, .{
            .namespace = pkg.namespace(),
            .limits = options.limits,
            .resolver = loader.resolver(),
        }, diags) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                failed = true;
                continue;
            },
        };
        errdefer doc.deinit(gpa);
        try docs.append(gpa, doc);
    }

    // 2. Every schema in the package, before any record is checked — a record in the first
    //    file may instantiate a schema declared in the last.
    for (docs.items) |*doc| {
        pkg.registerSchemas(gpa, doc, registry, diags) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ContentInvalid => failed = true,
        };
    }

    // 3. Every authored record. Checking continues past a bad one so that a package with
    //    six mistakes takes one build to find them all.
    for (docs.items) |*doc| {
        pkg.addRecords(gpa, doc, registry, diags) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ContentInvalid => failed = true,
        };
    }

    // 4. Derived asset records, materialised as text and compiled by the same parser and
    //    the same checker the authored ones went through.
    const derived_source = derive(gpa, arena.allocator(), &walk, &pkg, registry, diags) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ContentInvalid => blk: {
            failed = true;
            break :blk null;
        },
    };
    if (derived_source) |source| {
        var doc = data.parser.parse(gpa, derived_file, source, .{
            .namespace = pkg.namespace(),
            .limits = options.limits,
        }, diags) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ContentInvalid,
        };
        defer doc.deinit(gpa);
        pkg.addRecords(gpa, &doc, registry, diags) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ContentInvalid => failed = true,
        };
    }

    if (failed or diags.failed) return error.ContentInvalid;

    data.fpk.write(gpa, &pkg, registry, out) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diags.addFmt(gpa, .err, .whole(dir), 1, "", "could not be written: {s}", .{@errorName(err)});
            return error.ContentInvalid;
        },
    };
}

/// The name derived records are reported against.
///
/// Angle brackets because it is not a path and must never be mistaken for one: nothing on
/// disk can be opened to find the line a diagnostic points at, and the whole point of
/// derivation is that the file it describes was not written by anyone.
pub const derived_file = "<derived>";

// ---------------------------------------------------------------------------
// Walking the package
// ---------------------------------------------------------------------------

/// What a package directory contains, in one deterministic order.
pub const Walk = struct {
    /// Package-relative paths of `.fdt` files, sorted.
    sources: std.ArrayList([]const u8) = .empty,
    /// Package-relative paths of files whose extension names an asset kind, sorted.
    assets: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Walk, gpa: Allocator) void {
        self.sources.deinit(gpa);
        self.assets.deinit(gpa);
        self.* = undefined;
    }

    /// Walks `root` recursively. Paths are allocated in `arena` and use `/` on every
    /// platform, because they are content-relative names rather than OS paths.
    ///
    /// **Dot-prefixed names are skipped**, files and directories alike. `.git`, `.DS_Store`
    /// and an editor's swap files are not content, and a package that had to list its
    /// exclusions would be a package with a manifest.
    pub fn run(
        gpa: Allocator,
        arena: Allocator,
        os: *Os,
        root: []const u8,
        diags: *Diagnostics,
    ) Error!Walk {
        var self: Walk = .{};
        errdefer self.deinit(gpa);
        try self.descend(gpa, arena, os, root, "", diags);
        return self;
    }

    fn descend(
        self: *Walk,
        gpa: Allocator,
        arena: Allocator,
        os: *Os,
        root: []const u8,
        prefix: []const u8,
        diags: *Diagnostics,
    ) Error!void {
        const absolute = if (prefix.len == 0)
            try arena.dupe(u8, root)
        else
            platform.os.joinPath(arena, &.{ root, prefix }) catch return error.IoFailed;

        var listing = os.listDir(gpa, absolute) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Reported here rather than left for the caller, because here is the only place
            // that knows *which* directory and *why*. One message per problem.
            else => {
                try diags.addFmt(gpa, .err, .whole(absolute), 1, "", "cannot be read as a package directory: {s}", .{@errorName(err)});
                return error.IoFailed;
            },
        };
        defer listing.deinit();

        // The filesystem's order is not a specification (I9).
        const entries = try gpa.dupe(platform.os.DirEntry, listing.entries);
        defer gpa.free(entries);
        std.mem.sort(platform.os.DirEntry, entries, {}, lessByName);

        for (entries) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            const rel = if (prefix.len == 0)
                try arena.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });

            switch (entry.kind) {
                .directory => try self.descend(gpa, arena, os, root, rel, diags),
                .file => {
                    const ext = extensionOf(entry.name);
                    if (std.mem.eql(u8, ext, source_extension)) {
                        try self.sources.append(gpa, rel);
                    } else if (asset.schemas.kindForExtension(ext) != null) {
                        try self.assets.append(gpa, rel);
                    }
                },
                .other => {},
            }
        }
    }

    fn lessByName(_: void, a: platform.os.DirEntry, b: platform.os.DirEntry) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

/// The extension of a file name, without the dot, or empty if it has none.
///
/// A leading dot does not begin an extension — but dot-prefixed names never reach here,
/// which is the same rule stated twice and is worth keeping true in both places.
pub fn extensionOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0) return "";
    return name[dot + 1 ..];
}

// ---------------------------------------------------------------------------
// Reading, and answering `@import`
// ---------------------------------------------------------------------------

/// Reads files under one root, and is the `@import` resolver for the parse.
///
/// Holds every file it read for the life of the compile, because the parse tree borrows
/// source bytes and a diagnostic borrows the line it points at.
const Loader = struct {
    gpa: Allocator,
    arena: Allocator,
    os: *Os,
    root: []const u8,
    options: Options,
    /// Canonical relative path to the bytes read for it, so a diamond `@import` reads the
    /// file once and the parser's cycle detection sees one name for it.
    files: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn deinit(self: *Loader) void {
        self.files.deinit(self.gpa);
    }

    fn read(self: *Loader, rel: []const u8) ![]const u8 {
        if (self.files.get(rel)) |bytes| return bytes;
        const absolute = try platform.os.joinPath(self.arena, &.{ self.root, rel });
        const bytes = try self.os.readFile(self.arena, absolute, self.options.max_source_bytes);
        try self.files.put(self.gpa, rel, bytes);
        return bytes;
    }

    fn resolver(self: *Loader) data.parser.Resolver {
        return .{ .ctx = self, .resolveFn = resolve };
    }

    /// `@import "shared/items.fdt"` — relative to the importing file's directory, never
    /// escaping the package root.
    ///
    /// A path is untrusted input like everything else a package contains: `..` that climbs
    /// out is a distinct answer from "not found", because it is a different mistake with a
    /// different fix, and because a content compiler that could be talked into reading
    /// `../../../.ssh/id_rsa` would be a content compiler with a security bug.
    fn resolve(ctx: *anyopaque, importer: []const u8, requested: []const u8) data.parser.Resolution {
        const self: *Loader = @ptrCast(@alignCast(ctx));
        const dir = std.fs.path.dirnamePosix(importer) orelse "";
        const joined = if (dir.len == 0)
            self.arena.dupe(u8, requested) catch return .not_found
        else
            std.fmt.allocPrint(self.arena, "{s}/{s}", .{ dir, requested }) catch return .not_found;

        const canonical = (normalize(self.arena, joined) catch return .not_found) orelse return .outside_package;
        const bytes = self.read(canonical) catch return .not_found;
        return .{ .found = .{ .name = canonical, .bytes = bytes } };
    }
};

/// Resolves `.` and `..` inside a package-relative path, or null if it climbs out.
///
/// Textual, and deliberately so: it never asks the filesystem, so it cannot be defeated by
/// a symlink that exists between the check and the read, and it gives the same answer on
/// every machine.
fn normalize(arena: Allocator, path: []const u8) Allocator.Error!?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(arena);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len == 0) return null;
            _ = parts.pop();
            continue;
        }
        try parts.append(arena, part);
    }
    if (parts.items.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    for (parts.items, 0..) |part, i| {
        if (i > 0) try out.append(arena, '/');
        try out.appendSlice(arena, part);
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Derivation
// ---------------------------------------------------------------------------

/// The `.fdt` text for every asset file that does not already have a record, or null if
/// there is none.
///
/// Text, rather than records built directly, because `assets.md` §3 says a derived ID is
/// materialised "exactly as if it had been written by hand" — and the cheapest way to be
/// sure of that is for it to go through the same parser and the same checker. A derived
/// record that collides with an authored one then reports itself with the note the checker
/// already writes, instead of with a second implementation of the same complaint.
fn derive(
    gpa: Allocator,
    arena: Allocator,
    walk: *const Walk,
    pkg: *const data.Package,
    registry: *Registry,
    diags: *Diagnostics,
) (error{ContentInvalid} || Allocator.Error)!?[]const u8 {
    // Which files authored records already speak for. Explicit always beats implicit, and
    // never silently duplicates it (`assets.md` §3).
    var spoken_for: std.StringHashMapUnmanaged(void) = .empty;
    defer spoken_for.deinit(gpa);
    for (pkg.records()) |record| {
        const schema = registry.get(record.schema) orelse continue;
        if (asset.schemas.kindForSchema(record.schema_id) == null) continue;
        const index = schema.fieldIndex(asset.schemas.source_field) orelse continue;
        const value = record.value(schema.*, index) orelse continue;
        if (value != .string) continue;
        try spoken_for.put(gpa, value.string, {});
    }

    const namespace = pkg.namespace();
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(arena);

    // Which path minted which id, so a collision names both files rather than the second.
    var minted: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer minted.deinit(gpa);

    var failed = false;
    for (walk.assets.items) |rel| {
        if (spoken_for.contains(rel)) continue;
        const kind = asset.schemas.kindForExtension(extensionOf(rel)).?;

        const id = deriveId(arena, namespace, rel) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                failed = true;
                try diags.addFmt(gpa, .err, .whole(rel), 1, "", "cannot derive a content id from this path: {s}. Rename the file so every part of its path is a valid id segment ([a-z][a-z0-9_]*), or write a '{s}' record for it and give the id explicitly", .{ describeDeriveError(err), kind.name });
                continue;
            },
        };

        if (try minted.fetchPut(gpa, id, rel)) |first| {
            failed = true;
            try diags.addFmt(gpa, .err, .whole(rel), 1, "", "derives the same content id '{s}' as '{s}'; two files cannot be one asset, so rename one or give both ids explicitly", .{ id, first.value });
            continue;
        }

        try text.print(arena, "{s} {s} {{ {s} \"{s}\" }}\n", .{
            kind.name,
            id,
            asset.schemas.source_field,
            rel,
        });
    }

    if (failed) return error.ContentInvalid;
    if (text.items.len == 0) return null;
    return text.items;
}

pub const DeriveError = error{
    /// A path segment that is not `[a-z][a-z0-9_]*`.
    InvalidSegment,
    /// A file with no extension, or one whose name is nothing but an extension.
    NoStem,
} || Allocator.Error;

/// `textures/ui/panel.png` in package `foundry` becomes `foundry:textures.ui.panel`.
///
/// Drop the extension, replace each `/` with `.`, prefix the namespace. A pure function of
/// the path and only of the path: it does not consult the file's contents, its kind or its
/// loader, so a mod author can compute an asset's id by looking at it, which is most of the
/// value (`assets.md` §3).
///
/// **It transforms nothing.** `Panel-01.png` is an error, not `panel_01`. A transformation
/// would be a second specification that every external mod tool would have to reimplement
/// identically, and any divergence would produce ids that differ invisibly — the same
/// reasoning `core/id.zig` gives for spelling out FNV-1a rather than calling a library.
pub fn deriveId(arena: Allocator, namespace: []const u8, rel: []const u8) DeriveError![]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, rel, '.') orelse return error.NoStem;
    const stem = rel[0..dot];
    if (stem.len == 0) return error.NoStem;
    if (std.mem.lastIndexOfScalar(u8, stem, '/')) |slash| {
        if (slash + 1 == stem.len) return error.NoStem;
    }

    var it = std.mem.splitScalar(u8, stem, '/');
    while (it.next()) |segment| {
        if (!data.id.isValidSegment(segment)) return error.InvalidSegment;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    try out.appendSlice(arena, namespace);
    try out.append(arena, ':');
    for (stem) |c| try out.append(arena, if (c == '/') '.' else c);
    return out.items;
}

fn describeDeriveError(err: DeriveError) []const u8 {
    return switch (err) {
        error.InvalidSegment => "a part of it is not lowercase letters, digits and underscores starting with a letter",
        error.NoStem => "it has no name left once the extension is removed",
        error.OutOfMemory => "out of memory",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "an id is derived from a path, and only from a path" {
    var arena: core.Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("foundry:textures.ui.panel", try deriveId(a, "foundry", "textures/ui/panel.png"));
    try testing.expectEqualStrings("foundry:shaders.water", try deriveId(a, "foundry", "shaders/water.msl"));
    try testing.expectEqualStrings("mymod:sprites", try deriveId(a, "mymod", "sprites.png"));
    try testing.expectEqualStrings("foundry:a.b.c.d", try deriveId(a, "foundry", "a/b/c/d.png"));

    // Nothing is transformed on the way through.
    try testing.expectError(error.InvalidSegment, deriveId(a, "foundry", "Panel-01.png"));
    try testing.expectError(error.InvalidSegment, deriveId(a, "foundry", "ui/Panel.png"));
    try testing.expectError(error.InvalidSegment, deriveId(a, "foundry", "1st/panel.png"));
    try testing.expectError(error.NoStem, deriveId(a, "foundry", "panel"));
    try testing.expectError(error.NoStem, deriveId(a, "foundry", ".png"));
    try testing.expectError(error.NoStem, deriveId(a, "foundry", "ui/.png"));
}

test "an extension is what follows the last dot, and a leading dot is not one" {
    try testing.expectEqualStrings("png", extensionOf("panel.png"));
    try testing.expectEqualStrings("png", extensionOf("panel.tar.png"));
    try testing.expectEqualStrings("", extensionOf("panel"));
    try testing.expectEqualStrings("", extensionOf(".gitignore"));
}

test "an import path is resolved textually, and cannot climb out of the package" {
    var arena: core.Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("items/torch.fdt", (try normalize(a, "items/torch.fdt")).?);
    try testing.expectEqualStrings("items/torch.fdt", (try normalize(a, "./items/./torch.fdt")).?);
    try testing.expectEqualStrings("torch.fdt", (try normalize(a, "items/../torch.fdt")).?);
    try testing.expect((try normalize(a, "../secrets.fdt")) == null);
    try testing.expect((try normalize(a, "items/../../secrets.fdt")) == null);
    try testing.expect((try normalize(a, "")) == null);
}

/// A package directory built in a temp dir, compiled, and read back.
///
/// The one thing in the pipeline that is not hermetic, and deliberately tested against a
/// real filesystem for exactly that reason: `data` is proven on byte buffers already, and
/// what is left to prove is what happens when the bytes come from a disk.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    os: *Os,
    root: []const u8,
    root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    registry: data.Registry,
    diags: Diagnostics,
    bytes: std.ArrayList(u8) = .empty,

    fn init() !*Fixture {
        const gpa = testing.allocator;
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);
        self.* = .{
            .tmp = testing.tmpDir(.{}),
            .os = try Os.init(gpa, .{ .app_name = "foundry-fpack-test" }),
            .root = "",
            .registry = .init(gpa, .default),
            .diags = .init(gpa, .default),
        };
        const n = try self.tmp.dir.realPath(testing.io, &self.root_buf);
        self.root = self.root_buf[0..n];
        return self;
    }

    fn deinit(self: *Fixture) void {
        const gpa = testing.allocator;
        self.bytes.deinit(gpa);
        self.diags.deinit(gpa);
        self.registry.deinit(gpa);
        self.os.deinit();
        self.tmp.cleanup();
        gpa.destroy(self);
    }

    /// Writes a file at a package-relative path, creating the directories above it.
    fn write(self: *Fixture, rel: []const u8, contents: []const u8) !void {
        const gpa = testing.allocator;
        const path = try platform.os.joinPath(gpa, &.{ self.root, rel });
        defer gpa.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.os.createDirPath(parent);
        try self.os.writeFile(path, contents);
    }

    fn compileIt(self: *Fixture, name: []const u8) Error!void {
        self.bytes.clearRetainingCapacity();
        return compile(testing.allocator, self.os, self.root, .{ .name = name }, &self.registry, &self.diags, &self.bytes);
    }

    fn open(self: *Fixture) !data.fpk.Reader {
        return data.fpk.Reader.open(testing.allocator, self.bytes.items, .default);
    }

    fn rendered(self: *Fixture, buf: []u8) ![]const u8 {
        var writer: std.Io.Writer = .fixed(buf);
        try self.diags.render(&writer);
        return writer.buffered();
    }
};

/// A 1x1 PNG. Never decoded here — `fpack` derives a record from a file's *path* and never
/// looks inside it (`assets.md` §3) — but a real one, so that nothing downstream has to
/// pretend.
const one_pixel_png = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00,
    0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

test "a directory of text and images compiles to a package that reads back" {
    var f = try Fixture.init();
    defer f.deinit();

    try f.write("items.fdt",
        \\@import "shared/schemas.fdt"
        \\
        \\item foundry:item.torch { name "Torch"  weight 0.5 }
    );
    try f.write("shared/schemas.fdt", "@schema item { name string  weight f32 (default 1.0) }");
    try f.write("textures/ui/panel.png", &one_pixel_png);
    try f.write("textures/sprites.png", &one_pixel_png);
    try f.write("readme.txt", "not content");
    try f.write(".hidden/ignored.fdt", "@schema nope { x i32 }");

    try f.compileIt("foundry:core");

    var r = try f.open();
    defer r.deinit();

    try testing.expectEqualStrings("foundry:core", r.name);
    // One item and two derived textures. The `.txt` is not an asset kind and the
    // dot-prefixed directory was never walked into.
    try testing.expectEqual(@as(u32, 3), r.record_count);

    const texture_schema = r.schemaFor(data.SchemaId.fromStringUnchecked("foundry:texture")).?;
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);
    for (0..r.record_count) |i| {
        const view = r.record(@intCast(i)).?;
        try seen.appendSlice(testing.allocator, view.name);
        if (view.schema_id.eql(texture_schema.id)) {
            const fields = r.fieldsOf(view, texture_schema.*);
            try seen.append(testing.allocator, '=');
            try seen.appendSlice(testing.allocator, (try fields.stringAt(0)).?);
        }
        try seen.append(testing.allocator, '\n');
    }

    // Authored records first, in file order; derived ones after, in walk order — which is
    // sorted, so it is the same on any machine (I9).
    try testing.expectEqualStrings(
        \\foundry:item.torch
        \\foundry:textures.sprites=textures/sprites.png
        \\foundry:textures.ui.panel=textures/ui/panel.png
        \\
    , seen.items);
}

test "compiling the same directory twice produces the same bytes" {
    var f = try Fixture.init();
    defer f.deinit();

    try f.write("a.fdt", "@schema item { name string }\nitem foundry:item.torch { name \"Torch\" }");
    try f.write("b/z.png", &one_pixel_png);
    try f.write("b/a.png", &one_pixel_png);
    try f.write("c.png", &one_pixel_png);

    try f.compileIt("foundry:core");
    const first = try testing.allocator.dupe(u8, f.bytes.items);
    defer testing.allocator.free(first);

    // A second registry, so nothing carries over but the directory itself.
    f.registry.deinit(testing.allocator);
    f.registry = .init(testing.allocator, .default);
    try f.compileIt("foundry:core");

    try testing.expectEqualSlices(u8, first, f.bytes.items);
}

test "an authored record beats derivation, and is not duplicated by it" {
    var f = try Fixture.init();
    defer f.deinit();

    try f.write("assets.fdt",
        \\foundry:texture foundry:texture.sprites { source "textures/sprites.png" }
    );
    try f.write("textures/sprites.png", &one_pixel_png);
    try f.write("textures/other.png", &one_pixel_png);

    try f.compileIt("foundry:core");

    var r = try f.open();
    defer r.deinit();

    // Two records: the authored one under the name its author chose, and one derived for
    // the file nobody spoke for.
    try testing.expectEqual(@as(u32, 2), r.record_count);
    try testing.expectEqualStrings("foundry:texture.sprites", r.record(0).?.name);
    try testing.expectEqualStrings("foundry:textures.other", r.record(1).?.name);
}

test "two files that derive one id are an error naming both" {
    var f = try Fixture.init();
    defer f.deinit();

    // `.msl` is not an asset kind yet, so a second `.png` under a name that differs only
    // in a directory cannot collide — this collides the honest way, by having the same
    // path with two extensions once shaders are kinds. Until then: the same stem twice.
    try f.write("sprites.png", &one_pixel_png);
    try f.write("nested/sprites.png", &one_pixel_png);
    try f.compileIt("foundry:core");

    // Different directories, different ids. Nothing collides.
    {
        var r = try f.open();
        defer r.deinit();
        try testing.expectEqual(@as(u32, 2), r.record_count);
    }

    // Now one that does: an authored record claiming the id derivation would mint.
    try f.write("claim.fdt",
        \\foundry:texture foundry:sprites { source "elsewhere/sprites.png" }
    );
    try testing.expectError(error.ContentInvalid, f.compileIt("foundry:core"));

    var buf: [2048]u8 = undefined;
    const text = try f.rendered(&buf);
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "is defined twice in this package"));
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, derived_file));
}

test "a path that cannot be an id says so, and says both ways out" {
    var f = try Fixture.init();
    defer f.deinit();

    try f.write("UI/Panel-01.png", &one_pixel_png);
    try testing.expectError(error.ContentInvalid, f.compileIt("foundry:core"));

    var buf: [2048]u8 = undefined;
    const text = try f.rendered(&buf);
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "UI/Panel-01.png: error: cannot derive a content id"));
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "Rename the file"));
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "foundry:texture"));
}

test "a mistake in the text is reported with the file, the line and a caret" {
    var f = try Fixture.init();
    defer f.deinit();

    try f.write("items.fdt",
        \\@schema item { name string }
        \\item foundry:item.torch { name 42 }
    );
    try testing.expectError(error.ContentInvalid, f.compileIt("foundry:core"));

    var buf: [2048]u8 = undefined;
    const text = try f.rendered(&buf);
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "items.fdt:2:32: error:"));
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "expects string, found integer"));
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "^~"));
}

test "an import that climbs out of the package is refused, and says which mistake it is" {
    var f = try Fixture.init();
    defer f.deinit();

    try f.write("items.fdt", "@import \"../outside.fdt\"\n");
    try testing.expectError(error.ContentInvalid, f.compileIt("foundry:core"));

    var buf: [2048]u8 = undefined;
    const text = try f.rendered(&buf);
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "outside"));
}

test "an empty directory is a package with nothing in it, not a failure" {
    var f = try Fixture.init();
    defer f.deinit();

    try f.compileIt("foundry:empty");

    var r = try f.open();
    defer r.deinit();
    try testing.expectEqual(@as(u32, 0), r.record_count);
    try testing.expectEqualStrings("foundry:empty", r.name);
}

test "a package name that is not an id is refused before anything is read" {
    var f = try Fixture.init();
    defer f.deinit();

    try testing.expectError(error.ContentInvalid, f.compileIt("not an id"));

    var buf: [1024]u8 = undefined;
    const text = try f.rendered(&buf);
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "is not a valid package name"));
}

test "a grid file derives a tilegrid record, and a map compiles against schemas nobody declared" {
    var f = try Fixture.init();
    defer f.deinit();

    // Real grid bytes, written by the engine's own writer -- which is the point of the
    // writer living in `asset` beside the reader rather than here.
    const grid = try asset.tilegrid.write(testing.allocator, 2, 2, &.{ 0, 1, 1, 0 });
    defer testing.allocator.free(grid);
    try f.write("grids/town/walls.fgrid", grid);

    // None of these three record types is declared anywhere in the package. They are
    // engine-owned and registered before the compile, which is why `fpack` has to be able
    // to see them without linking a renderer (`tilemaps-and-collision.md` §11).
    try f.write("map.fdt",
        \\foundry:tileset sandbox:tiles.overworld {
        \\    texture sandbox:textures.overworld
        \\    tile    [ 16 16 ]
        \\    columns 16
        \\    solid   [ 1 ]
        \\}
        \\
        \\foundry:tilemap.layer sandbox:map.town.walls {
        \\    tileset  sandbox:tiles.overworld
        \\    grid     sandbox:grids.town.walls
        \\    collides true
        \\}
        \\
        \\foundry:tilemap sandbox:map.town {
        \\    size   [ 2 2 ]
        \\    cell   [ 16 16 ]
        \\    layers [ sandbox:map.town.walls ]
        \\}
    );

    try f.compileIt("sandbox:content");

    var r = try f.open();
    defer r.deinit();

    // Three authored records and one derived grid.
    try testing.expectEqual(@as(u32, 4), r.record_count);

    const tilegrid_schema = r.schemaFor(data.SchemaId.fromStringUnchecked("foundry:tilegrid")).?;
    var found = false;
    for (0..r.record_count) |i| {
        const view = r.record(@intCast(i)).?;
        if (!view.schema_id.eql(tilegrid_schema.id)) continue;
        found = true;
        // The id comes from the path and the path alone (ADR-0021).
        try testing.expectEqualStrings("sandbox:grids.town.walls", view.name);
        const fields = r.fieldsOf(view, tilegrid_schema.*);
        try testing.expectEqualStrings("grids/town/walls.fgrid", (try fields.stringAt(0)).?);
    }
    try testing.expect(found);
}

test "an authored tilegrid record beats the one its path would derive" {
    var f = try Fixture.init();
    defer f.deinit();

    const grid = try asset.tilegrid.write(testing.allocator, 1, 1, &.{7});
    defer testing.allocator.free(grid);
    try f.write("grids/town/walls.fgrid", grid);
    try f.write("map.fdt",
        \\foundry:tilegrid sandbox:maps.the_town { source "grids/town/walls.fgrid" }
    );

    try f.compileIt("sandbox:content");

    var r = try f.open();
    defer r.deinit();

    // One record, not two: explicit always beats implicit and never silently duplicates it,
    // which is the rule assets already had and which a new kind inherits for free.
    try testing.expectEqual(@as(u32, 1), r.record_count);
    try testing.expectEqualStrings("sandbox:maps.the_town", r.record(0).?.name);
}
