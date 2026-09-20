//! The authoring service: workspaces a host granted, and what may be done with them.
//!
//! **This is the thing the public table publishes** (ADR-0042, `editor.md` §4 and §9). A
//! host constructs one, grants it directories and dependency files, and hands it to `abi`;
//! everything a client can reach is reached through a handle this issues. `abi` holds no
//! authoring state of its own, exactly as it holds no world and no renderer.
//!
//! **A grant is a capability and never a search.** The service opens the source root it was
//! given, reads the dependency files it was named, writes candidates below the output root
//! it was granted, exports only to destinations the host configured, and activates a preview
//! only through the host's own callback. There is no path parameter anywhere a client can
//! reach, so the worst a hostile client can do is name a handle that does not resolve.
//!
//! **Three things outlive one operation and are therefore owned here rather than by a
//! caller:** the workspaces themselves, the diagnostics of the most recent operation — which
//! `editor.md` §8 requires to stay readable until the next one replaces them — and what a
//! preview activation published. Everything else belongs to `workspace.Workspace`.
//!
//! The service is not thread-safe and is not meant to be: authoring calls run on the host
//! thread after UI description (§9), which is the same rule every other boundary call obeys.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");

const build_mod = @import("build.zig");
const dependency = @import("dependency.zig");
const save = @import("save.zig");
const workspace_mod = @import("workspace.zig");

const Allocator = std.mem.Allocator;
const Diagnostics = data.Diagnostics;
const Os = platform.os.Os;
const Workspace = workspace_mod.Workspace;

const log = core.log.scoped(.author);

/// Phantom tag for a workspace handle (I1). Never a `data` handle and never an index.
pub const Workspaces = opaque {};
pub const Handle = core.Handle(Workspaces);

/// How many workspaces one service can hold open at once.
///
/// `editor.md` §4 says the first editor handles one at a time, and the limit is the host's
/// to set. This is the fixed backing store behind that setting: small, because a second
/// workspace is a second granted root and a host that wants four has said so four times.
pub const max_workspaces = 4;

pub const Error = error{
    /// Well-formed and stale, or never issued.
    InvalidHandle,
    /// More workspaces than this service was configured to hold.
    Limit,
    /// No host callback for activating a build, so there is nothing to preview with.
    PreviewUnavailable,
    /// The host's activation declined, or the build no longer exists. The previous preview,
    /// if there was one, is untouched.
    PreviewRefused,
    /// The build being released is the one a preview is holding.
    PreviewHoldsBuild,
    /// No destination with that number, or the host configured none.
    ExportUnavailable,
    IoFailed,
    ContentInvalid,
} || Allocator.Error;

/// One place a host will let a successful build be written.
///
/// **A client names a destination by number, never a path** (§9). The host decides what the
/// numbers mean, which is what keeps an export from becoming an arbitrary file write with
/// extra steps: `fpack`'s legacy `--out`/`--assets-out` pair is one of these, and an
/// editor's "export this build" is another.
pub const ExportTarget = struct {
    /// What a client sees when it enumerates destinations. Borrowed from the host.
    name: []const u8,
    kind: Kind,
    /// An existing host-granted directory, and the package's name inside it. Every write is
    /// confined below the root and follows no link, as every other access here does.
    package_root: []const u8,
    package_name: []const u8,
    /// Where the destination's asset files go, or null for a destination that wants none.
    assets_root: ?[]const u8 = null,

    pub const Kind = enum {
        /// The compiled package, and only the assets the **compiler** produced. What
        /// `fpack` has always written, and the reason it is a kind rather than a flag:
        /// copying a package's ordinary assets beside its `.fpk` would be a new output
        /// set for a command line that has never had one.
        compiled,
        /// The complete runtime tree: the package and every asset it needs, ordinary and
        /// generated alike, as a game would install them.
        runtime,
    };
};

/// What a host publishes after it has loaded a candidate.
///
/// The store and registry stay the **host's**, alive until it activates another preview.
/// The service reads exact values out of them and owns neither, which is the same
/// arrangement `abi` has with a world.
pub const Publication = struct {
    content_generation: u64,
    store: *const data.Store,
    registry: *data.Registry,
};

/// Where a candidate is, for a host about to load it. Confined names, never a path a client
/// supplied: `directory` is the host's own output root.
pub const PreviewRequest = struct {
    /// The granted output root the candidate lives below.
    output_root: []const u8,
    /// The candidate's private directory, relative to that root.
    candidate: []const u8,
    /// The compiled package, relative to the output root.
    package: []const u8,
    /// Its runtime asset tree, relative to the output root.
    assets: []const u8,
    /// How many dependency packages the build captured. They are the bytes it was actually
    /// compiled against rather than whatever is on disk now, and they sit at
    /// `<candidate>/dependencies/<i>/package.fpk`, each with its asset tree beside it at
    /// `<candidate>/dependencies/<i>/assets` when the grant had one.
    dependency_count: u32,
};

/// The host's authority to make a build the loaded content.
///
/// Its absence is what makes preview unavailable, and editing, saving and building all still
/// work without it (§9). `abi` never loads anything itself; this callback is the only way a
/// successful build becomes runtime content.
pub const PreviewGrant = struct {
    ctx: ?*anyopaque = null,
    /// Loads the candidate and publishes it, or returns null having left the previous
    /// preview and its assets exactly as they were (§11).
    activate: *const fn (ctx: ?*anyopaque, request: PreviewRequest) ?Publication,
};

pub const Preview = struct {
    outcome: Outcome = .none,
    /// The build the preview holds. It cannot be released while it is held.
    build: build_mod.Handle = .none,
    /// The workspace revision that build was made at.
    revision: u64 = 0,
    content_generation: u64 = 0,
    store: ?*const data.Store = null,
    registry: ?*data.Registry = null,

    pub const Outcome = enum {
        /// Nothing has been activated in this workspace.
        none,
        /// The loaded content is this build's.
        active,
        /// The last request was declined; whatever was loaded before is still loaded.
        failed,
    };
};

/// What a host hands over when it opens a workspace, beyond the workspace's own options.
pub const OpenOptions = struct {
    workspace: workspace_mod.Options = .{},
    /// Borrowed for the life of the workspace, like every other grant here.
    exports: []const ExportTarget = &.{},
    preview: ?PreviewGrant = null,
};

pub const Options = struct {
    /// How many workspaces may be open at once. One, until a host says otherwise.
    max_open: u32 = 1,
    /// The bound every operation's diagnostic snapshot is collected under.
    diagnostics: data.Limits = .default,
};

/// One open workspace and everything the service keeps beside it.
pub const Entry = struct {
    workspace: Workspace,
    exports: []const ExportTarget,
    preview_grant: ?PreviewGrant,
    preview: Preview = .{},
    /// The most recent operation's diagnostics. Replaced wholesale by the next operation,
    /// which is what makes "readable until the next one" a property of the code rather than
    /// a promise (`editor.md` §8).
    diags: Diagnostics,
    /// The workspace revision the snapshot above was collected at.
    diags_revision: u64 = 0,
    /// The last Save All's per-file results, in the order it processed them.
    save_entries: []save.AllEntry = &.{},
    save_entry_count: usize = 0,

    /// Clears the diagnostic snapshot so the operation about to run owns it alone.
    pub fn begin(self: *Entry, gpa: Allocator) void {
        const limits = self.diags.limits;
        self.diags.deinit(gpa);
        self.diags = .init(gpa, limits);
    }

    /// Stamps the snapshot with the revision it describes.
    pub fn end(self: *Entry, revision: u64) void {
        self.diags_revision = revision;
    }

    fn deinit(self: *Entry, gpa: Allocator) void {
        self.workspace.deinit();
        self.diags.deinit(gpa);
        gpa.free(self.save_entries);
        self.* = undefined;
    }
};

const Slot = struct {
    /// Bumped every time the slot is reused, so a handle to a closed workspace fails to
    /// resolve rather than naming its successor (I1). Zero means never used.
    generation: u32 = 0,
    entry: ?Entry = null,
};

pub const Service = struct {
    gpa: Allocator,
    os: *Os,
    options: Options,
    slots: [max_workspaces]Slot = @splat(.{}),
    open_count: u32 = 0,
    /// Moved by every successful mutation in any workspace. Cursors carry it, so a walk
    /// begun before an edit is refused rather than resynchronised onto a different list.
    generation: u32 = 1,
    next_generation: u32 = 0,

    pub fn init(gpa: Allocator, os: *Os, options: Options) Service {
        return .{ .gpa = gpa, .os = os, .options = options };
    }

    pub fn deinit(self: *Service) void {
        for (&self.slots) |*slot| {
            if (slot.entry) |*open_entry| open_entry.deinit(self.gpa);
            slot.entry = null;
        }
        self.* = undefined;
    }

    /// Opens a granted directory and publishes it.
    ///
    /// Content mistakes are diagnostics on a workspace that still opens — a directory with
    /// no manifest is where a new package starts — so this fails only when the workspace
    /// itself could not be made.
    pub fn open(
        self: *Service,
        root: []const u8,
        options: OpenOptions,
        diags: *Diagnostics,
    ) (Error || workspace_mod.Error)!Handle {
        if (self.open_count >= self.options.max_open) return error.Limit;
        const index = for (&self.slots, 0..) |*slot, i| {
            if (slot.entry == null) break i;
        } else return error.Limit;

        var opened = try Workspace.open(self.gpa, self.os, root, options.workspace, diags);
        errdefer opened.deinit();

        const slot = &self.slots[index];
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        slot.generation = self.next_generation;
        slot.entry = .{
            .workspace = opened,
            .exports = options.exports,
            .preview_grant = options.preview,
            .diags = .init(self.gpa, self.options.diagnostics),
        };
        self.open_count += 1;
        self.moved();
        return .{ .index = @intCast(index), .generation = slot.generation };
    }

    /// Closes one. Its candidates go with it, as `workspace.deinit` already arranges; the
    /// preview a host published is the host's to release.
    pub fn close(self: *Service, handle: Handle) void {
        const slot = self.slotOf(handle) orelse return;
        slot.entry.?.deinit(self.gpa);
        slot.entry = null;
        self.open_count -= 1;
        self.moved();
    }

    pub fn count(self: *const Service) u32 {
        return self.open_count;
    }

    /// The handle at one position of a stable enumeration: slot order, which never changes
    /// while a workspace is open.
    pub fn at(self: *const Service, position: u32) ?Handle {
        var seen: u32 = 0;
        for (&self.slots, 0..) |*slot, i| {
            if (slot.entry == null) continue;
            if (seen == position) return .{ .index = @intCast(i), .generation = slot.generation };
            seen += 1;
        }
        return null;
    }

    pub fn entry(self: *Service, handle: Handle) ?*Entry {
        const slot = self.slotOf(handle) orelse return null;
        return &slot.entry.?;
    }

    pub fn workspace(self: *Service, handle: Handle) ?*Workspace {
        return &(self.entry(handle) orelse return null).workspace;
    }

    /// Called after anything that invalidates an outstanding walk.
    pub fn moved(self: *Service) void {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }

    fn slotOf(self: *const Service, handle: Handle) ?*Slot {
        if (handle.index >= max_workspaces) return null;
        const slot = &@constCast(self).slots[handle.index];
        if (slot.entry == null) return null;
        if (slot.generation == 0 or slot.generation != handle.generation) return null;
        return slot;
    }

    // -- Preview ---------------------------------------------------------------------

    /// Asks the host to make a successful build the loaded content.
    ///
    /// The service does not load anything and does not know how: it resolves the build,
    /// describes where the candidate is, and records what came back. A declined activation
    /// is a recorded outcome rather than an error state — the previous preview is still
    /// loaded, and the editor's job is to say so.
    pub fn activatePreview(self: *Service, handle: Handle, build: build_mod.Handle) Error!void {
        const item = self.entry(handle) orelse return error.InvalidHandle;
        const grant = item.preview_grant orelse return error.PreviewUnavailable;
        const output_root = item.workspace.output_root orelse return error.PreviewUnavailable;

        const info = item.workspace.buildInfo(build) catch return error.InvalidHandle;

        const package = try std.fmt.allocPrint(self.gpa, "{s}/runtime/package.fpk", .{info.relative_dir});
        defer self.gpa.free(package);
        const assets = try std.fmt.allocPrint(self.gpa, "{s}/runtime/assets", .{info.relative_dir});
        defer self.gpa.free(assets);

        const published = grant.activate(grant.ctx, .{
            .output_root = output_root,
            .candidate = info.relative_dir,
            .package = package,
            .assets = assets,
            .dependency_count = item.workspace.dependencies.count(),
        }) orelse {
            item.preview.outcome = .failed;
            self.moved();
            return error.PreviewRefused;
        };

        item.preview = .{
            .outcome = .active,
            .build = build,
            .revision = info.revision,
            .content_generation = published.content_generation,
            .store = published.store,
            .registry = published.registry,
        };
        self.moved();
    }

    /// Releasing a build a preview is holding would delete files the loaded content is
    /// reading (§8). Refused, rather than left to the filesystem to notice.
    pub fn releaseBuild(self: *Service, handle: Handle, build: build_mod.Handle) Error!void {
        const item = self.entry(handle) orelse return error.InvalidHandle;
        if (item.preview.outcome == .active and item.preview.build.eql(build)) return error.PreviewHoldsBuild;
        item.begin(self.gpa);
        item.workspace.releaseBuild(build, &item.diags) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidHandle => return error.InvalidHandle,
            else => return error.IoFailed,
        };
        item.end(item.workspace.revision());
        self.moved();
    }

    // -- Export ----------------------------------------------------------------------

    /// Writes a successful build to one of the destinations the host configured.
    ///
    /// **Individual files, each replaced atomically, and a partial result reported as one**
    /// (§9). Only the private candidate has the all-or-nothing guarantee; a destination is
    /// somebody else's directory, and claiming a transaction over it would be a lie the
    /// first failed write exposes.
    pub fn exportBuild(
        self: *Service,
        handle: Handle,
        build: build_mod.Handle,
        target_index: u32,
    ) Error!u32 {
        const item = self.entry(handle) orelse return error.InvalidHandle;
        if (target_index >= item.exports.len) return error.ExportUnavailable;
        const target = item.exports[target_index];
        const output_root = item.workspace.output_root orelse return error.ExportUnavailable;
        const info = item.workspace.buildInfo(build) catch return error.InvalidHandle;

        item.begin(self.gpa);
        defer item.end(item.workspace.revision());

        var written: u32 = 0;
        self.publishFile(target.package_root, target.package_name, info.package_bytes) catch |err| {
            try item.diags.addFmt(self.gpa, .err, .whole(target.package_name), 1, "", "could not be written to '{s}': {s}", .{ target.name, @errorName(err) });
            return error.IoFailed;
        };
        written += 1;

        const assets_root = target.assets_root orelse return written;
        const source_dir = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{
            info.relative_dir,
            switch (target.kind) {
                .compiled => "generated",
                .runtime => "runtime/assets",
            },
        });
        defer self.gpa.free(source_dir);

        var files: Listing = try .init(self.gpa);
        defer files.deinit();
        files.collect(self.os, output_root, source_dir, "") catch |err| {
            try item.diags.addFmt(self.gpa, .err, .whole(target.name), 1, "", "the build's assets could not be listed: {s}", .{@errorName(err)});
            return error.IoFailed;
        };

        for (files.items.items) |relative| {
            const from = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ source_dir, relative });
            defer self.gpa.free(from);
            const read = self.os.readFileConfined(self.gpa, output_root, from, max_export_bytes) catch |err| {
                try item.diags.addFmt(self.gpa, .err, .whole(relative), 1, "", "could not be read out of the build: {s}", .{@errorName(err)});
                return error.IoFailed;
            };
            defer self.gpa.free(read.bytes);
            self.publishFile(assets_root, relative, read.bytes) catch |err| {
                try item.diags.addFmt(self.gpa, .err, .whole(relative), 1, "", "could not be written to '{s}' after {d} file(s): {s}", .{ target.name, written, @errorName(err) });
                return error.IoFailed;
            };
            written += 1;
        }
        return written;
    }

    /// One file, into a host-granted directory, creating the directories it needs.
    fn publishFile(self: *Service, root: []const u8, relative: []const u8, bytes: []const u8) !void {
        self.os.createDirPath(root) catch |err| switch (err) {
            error.AlreadyExists => {},
            else => return err,
        };
        if (std.fs.path.dirnamePosix(relative)) |parent| {
            self.os.createDirPathConfined(root, parent) catch |err| switch (err) {
                error.AlreadyExists => {},
                else => return err,
            };
        }
        _ = try self.os.replaceFileConfined(root, relative, bytes, max_export_bytes);
    }
};

/// The most one exported file may be. Above the compiler's own source bound, because an
/// asset is not a source file, and bounded all the same because this reads a directory.
pub const max_export_bytes: usize = 256 * 1024 * 1024;

/// How many files one export may write, and how deep it may look.
pub const max_export_files: usize = 4096;
pub const max_export_depth: usize = 16;

/// A bounded, sorted list of the files below one directory. Small enough to keep here
/// rather than reach into `build.zig`'s snapshot walker, which is tied to a build context.
const Listing = struct {
    arena: core.Arena,
    items: std.ArrayList([]const u8) = .empty,
    gpa: Allocator,

    fn init(gpa: Allocator) Allocator.Error!Listing {
        return .{ .arena = .init(gpa), .gpa = gpa };
    }

    fn deinit(self: *Listing) void {
        self.items.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    fn collect(self: *Listing, os: *Os, root: []const u8, base: []const u8, prefix: []const u8) !void {
        const depth = if (prefix.len == 0) 0 else std.mem.count(u8, prefix, "/") + 1;
        if (depth > max_export_depth) return error.Limit;

        const at = if (prefix.len == 0) base else try std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ base, prefix });
        var listing = os.listDirConfined(self.gpa, root, at) catch |err| switch (err) {
            // A build with nothing to generate has no `generated` directory, and that is
            // the ordinary case rather than a failure to report.
            error.FileNotFound => return,
            else => return err,
        };
        defer listing.deinit();

        const entries = try self.gpa.dupe(platform.os.DirEntry, listing.entries);
        defer self.gpa.free(entries);
        std.mem.sort(platform.os.DirEntry, entries, {}, lessEntry);

        for (entries) |item| {
            if (self.items.items.len >= max_export_files) return error.Limit;
            const relative = if (prefix.len == 0)
                try self.arena.allocator().dupe(u8, item.name)
            else
                try std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ prefix, item.name });
            switch (item.kind) {
                .directory => try self.collect(os, root, base, relative),
                .file => try self.items.append(self.gpa, relative),
                .other => return error.Unexpected,
            }
        }
    }
};

fn lessEntry(_: void, a: platform.os.DirEntry, b: platform.os.DirEntry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

/// A granted source root, a granted output root and a destination, all inside one
/// temporary directory — the shape a host actually hands this service.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    os: *Os,
    base: []const u8 = "",
    base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    owned: std.ArrayList([]const u8) = .empty,
    diags: Diagnostics,

    fn init() !*Fixture {
        const gpa = testing.allocator;
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);
        self.* = .{
            .tmp = testing.tmpDir(.{}),
            .os = try Os.init(gpa, .{ .app_name = "foundry-author-service-test" }),
            .diags = .init(gpa, .default),
        };
        const n = try self.tmp.dir.realPath(testing.io, &self.base_buf);
        self.base = self.base_buf[0..n];
        try self.os.createDirPath(try self.at("src"));
        try self.os.createDirPath(try self.at("out"));
        return self;
    }

    fn deinit(self: *Fixture) void {
        const gpa = testing.allocator;
        self.diags.deinit(gpa);
        for (self.owned.items) |path| gpa.free(path);
        self.owned.deinit(gpa);
        self.os.deinit();
        self.tmp.cleanup();
        gpa.destroy(self);
    }

    fn at(self: *Fixture, rel: []const u8) ![]const u8 {
        const gpa = testing.allocator;
        const path = try platform.os.joinPath(gpa, &.{ self.base, rel });
        errdefer gpa.free(path);
        try self.owned.append(gpa, path);
        return path;
    }

    fn root(self: *Fixture) ![]const u8 {
        return self.at("src");
    }

    fn out(self: *Fixture) ![]const u8 {
        return self.at("out");
    }

    fn dest(self: *Fixture) ![]const u8 {
        return self.at("dest");
    }

    fn write(self: *Fixture, rel: []const u8, text: []const u8) !void {
        const gpa = testing.allocator;
        const path = try platform.os.joinPath(gpa, &.{ self.base, "src", rel });
        defer gpa.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.os.createDirPath(parent);
        try self.os.writeFile(path, text);
    }

    fn manifest(self: *Fixture, id: []const u8, version: u32) !void {
        const gpa = testing.allocator;
        const text = try std.fmt.allocPrint(gpa,
            \\foundry:mod {s} {{
            \\  name "Fixture"
            \\  version {d}
            \\  license "Apache-2.0"
            \\}}
            \\
        , .{ id, version });
        defer gpa.free(text);
        try self.write("mod.fdt", text);
    }
};

test "a service issues generational workspace handles and refuses a closed one" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.manifest("demo:svc", 1);

    var service: Service = .init(testing.allocator, f.os, .{ .max_open = 2 });
    defer service.deinit();

    const first = try service.open(try f.root(), .{}, &f.diags);
    try testing.expectEqual(@as(u32, 1), service.count());
    try testing.expect(service.workspace(first) != null);
    try testing.expect(first.eql(service.at(0).?));

    // A second granted root is a second workspace, and a third is over the configured
    // bound rather than a silently larger service.
    const second = try service.open(try f.root(), .{}, &f.diags);
    try testing.expectEqual(@as(u32, 2), service.count());
    try testing.expectError(error.Limit, service.open(try f.root(), .{}, &f.diags));

    // A closed workspace's handle resolves to nothing, and the slot it used does not
    // resurrect it for whoever opens next (I1).
    const before = service.generation;
    service.close(first);
    try testing.expect(service.generation != before);
    try testing.expectEqual(@as(?*Workspace, null), service.workspace(first));
    try testing.expect(service.workspace(second) != null);

    const third = try service.open(try f.root(), .{}, &f.diags);
    try testing.expect(!third.eql(first));
    try testing.expectEqual(@as(?*Workspace, null), service.workspace(first));

    // Invented handles are refused the same way a stale one is.
    try testing.expectEqual(@as(?*Workspace, null), service.workspace(.{ .index = max_workspaces, .generation = 1 }));
    try testing.expectEqual(@as(?*Workspace, null), service.workspace(.none));
}

test "a preview is the host's to activate, and holds the build it activated" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.manifest("demo:preview", 1);

    const Grant = struct {
        var calls: u32 = 0;
        var refuse = false;
        var store: data.Store = undefined;
        var registry: data.Registry = undefined;

        fn activate(_: ?*anyopaque, request: PreviewRequest) ?Publication {
            calls += 1;
            // What a host is handed is a confined location below its own output root,
            // never a path a client supplied.
            std.debug.assert(std.mem.endsWith(u8, request.package, "/runtime/package.fpk"));
            std.debug.assert(std.mem.startsWith(u8, request.package, request.candidate));
            if (refuse) return null;
            return .{ .content_generation = 7, .store = &store, .registry = &registry };
        }
    };
    Grant.calls = 0;
    Grant.refuse = false;
    Grant.store = .init(testing.allocator, .default);
    defer Grant.store.deinit(testing.allocator);
    Grant.registry = .init(testing.allocator, .default);
    defer Grant.registry.deinit(testing.allocator);

    var service: Service = .init(testing.allocator, f.os, .{});
    defer service.deinit();
    const handle = try service.open(try f.root(), .{
        .workspace = .{
            .output_root = try f.out(),
            .grants = .{ .edit = true, .save = true, .build = true },
        },
        .preview = .{ .activate = Grant.activate },
    }, &f.diags);

    const item = service.entry(handle).?;
    const build = try item.workspace.build(item.workspace.revision(), &f.diags);

    try service.activatePreview(handle, build);
    try testing.expectEqual(@as(u32, 1), Grant.calls);
    try testing.expectEqual(Preview.Outcome.active, item.preview.outcome);
    try testing.expectEqual(@as(u64, 7), item.preview.content_generation);

    // The loaded content is reading the candidate's files, so releasing it is refused
    // rather than left for the filesystem to discover.
    try testing.expectError(error.PreviewHoldsBuild, service.releaseBuild(handle, build));

    // A declined activation records the refusal and leaves the previous preview loaded.
    Grant.refuse = true;
    const again = try item.workspace.build(item.workspace.revision(), &f.diags);
    try testing.expectError(error.PreviewRefused, service.activatePreview(handle, again));
    try testing.expectEqual(Preview.Outcome.failed, item.preview.outcome);
    try testing.expectEqual(@as(u64, 7), item.preview.content_generation);
    try testing.expect(item.preview.build.eql(build));

    // The build nothing is previewing releases normally.
    try service.releaseBuild(handle, again);
}

test "a workspace with no preview grant still edits, saves and builds" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.manifest("demo:nopreview", 1);

    var service: Service = .init(testing.allocator, f.os, .{});
    defer service.deinit();
    const handle = try service.open(try f.root(), .{ .workspace = .{
        .output_root = try f.out(),
        .grants = .{ .edit = true, .save = true, .build = true },
    } }, &f.diags);

    const item = service.entry(handle).?;
    const build = try item.workspace.build(item.workspace.revision(), &f.diags);
    try testing.expect(item.workspace.buildCount() > 0);
    try testing.expectError(error.PreviewUnavailable, service.activatePreview(handle, build));
    try service.releaseBuild(handle, build);
}

test "export writes a build to a configured destination and never to a path a caller named" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.manifest("demo:export", 3);

    const destination = try f.dest();
    const targets = [_]ExportTarget{.{
        .name = "cli",
        .kind = .compiled,
        .package_root = destination,
        .package_name = "demo.fpk",
        .assets_root = destination,
    }};

    var service: Service = .init(testing.allocator, f.os, .{});
    defer service.deinit();
    const handle = try service.open(try f.root(), .{
        .workspace = .{ .output_root = try f.out(), .grants = .{ .edit = true, .save = true, .build = true } },
        .exports = &targets,
    }, &f.diags);

    const item = service.entry(handle).?;
    const build = try item.workspace.build(item.workspace.revision(), &f.diags);

    // One file for a package with nothing generated, and the bytes are the build's own.
    try testing.expectEqual(@as(u32, 1), try service.exportBuild(handle, build, 0));
    const written = try f.os.readFileConfined(testing.allocator, destination, "demo.fpk", 1 << 20);
    defer testing.allocator.free(written.bytes);
    const info = try item.workspace.buildInfo(build);
    try testing.expectEqualSlices(u8, info.package_bytes, written.bytes);

    // Exporting again replaces rather than refusing: a destination is a place a build is
    // published to, repeatedly.
    try testing.expectEqual(@as(u32, 1), try service.exportBuild(handle, build, 0));

    // A destination number the host did not configure is the only way to name one.
    try testing.expectError(error.ExportUnavailable, service.exportBuild(handle, build, 1));
    try testing.expectError(error.InvalidHandle, service.exportBuild(.none, build, 0));
}
