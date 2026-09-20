//! Stable authoring snapshots and isolated candidate builds.
//!
//! A candidate is a fresh, exclusively created directory below a host-granted output root.
//! Inputs are copied there under the same confined/no-follow rules used to open a workspace,
//! then inventoried and compared again before the one shared compiler sees them. Generated
//! files cannot enter the source tree, and no handle is published until compilation and an
//! ordinary load-order/store validation both succeed (ADR-0043).

const std = @import("std");
const core = @import("core");
const data = @import("data");
const mod = @import("mod");
const platform = @import("platform");

const compiler = @import("compiler.zig");
const dependency = @import("dependency.zig");
const edit = @import("edit.zig");
const save = @import("save.zig");

const Allocator = std.mem.Allocator;
const Diagnostics = data.Diagnostics;
const Document = edit.Document;
const Os = platform.os.Os;

pub const Builds = opaque {};
pub const Handle = core.Handle(Builds);

pub const Error = error{
    StaleRevision,
    InvalidState,
    DirtyDocuments,
    ExternalChange,
    BuildNotGranted,
    OutputUnavailable,
    BuildLimit,
    SnapshotLimit,
    ContentInvalid,
    IoFailed,
    Busy,
    InvalidHandle,
} || Allocator.Error;

pub const Limits = struct {
    max_source_bytes: usize,
    max_snapshot_bytes: usize,
    max_live_builds: u32,
    walk: compiler.Walk.Limits,
    content: data.Limits,
    dependencies: dependency.Limits,
};

pub const Context = struct {
    gpa: Allocator,
    os: *Os,
    source_root: []const u8,
    output_root: ?[]const u8,
    documents: []Document,
    dependencies: *const dependency.Set,
    revision: u64,
    build_granted: bool,
    /// Whether this workspace may also write source. Decides whether the cooperating
    /// writer's lock is taken at all: see `save.Lock.unheld`.
    write_granted: bool,
    limits: Limits,
    state: *State,
    sequence: *u64,
};

pub const Info = struct {
    revision: u64,
    package_name: []const u8,
    package_version: u32,
    package_bytes: []const u8,
    /// Private candidate location, borrowed until release. Step 5 hands only the handle to
    /// public consumers; a host uses this path to assemble its ordinary preview inputs.
    relative_dir: []const u8,
};

const Build = struct {
    relative_dir: []u8,
    identity: compiler.Identity,
    package_bytes: []u8,
    revision: u64,

    fn info(self: *const Build) Info {
        return .{
            .revision = self.revision,
            .package_name = self.identity.name,
            .package_version = self.identity.version,
            .package_bytes = self.package_bytes,
            .relative_dir = self.relative_dir,
        };
    }

    fn freeMemory(self: *Build, gpa: Allocator) void {
        gpa.free(self.relative_dir);
        gpa.free(self.identity.name);
        gpa.free(self.package_bytes);
        self.* = undefined;
    }
};

pub const State = struct {
    pool: core.HandlePool(Builds, Build) = .empty,

    pub fn deinit(self: *State, gpa: Allocator, os: *Os, output_root: ?[]const u8) void {
        var it = self.pool.iterator();
        while (it.next()) |entry| {
            if (output_root) |root| os.deleteTreeConfined(root, entry.value.relative_dir) catch |err| {
                core.log.scoped(.author).warn("could not remove candidate '{s}' while closing a workspace: {s}", .{ entry.value.relative_dir, @errorName(err) });
            };
            entry.value.freeMemory(gpa);
        }
        self.pool.deinit(gpa);
        self.* = .{};
    }

    pub fn count(self: *const State) u32 {
        return self.pool.count();
    }
};

pub fn info(ctx: Context, handle: Handle) Error!Info {
    const value = ctx.state.pool.getConst(handle) orelse return error.InvalidHandle;
    return value.info();
}

pub fn release(ctx: Context, handle: Handle, diags: *Diagnostics) Error!void {
    const value = ctx.state.pool.get(handle) orelse return error.InvalidHandle;
    const output_root = ctx.output_root orelse return error.OutputUnavailable;
    ctx.os.deleteTreeConfined(output_root, value.relative_dir) catch |err| {
        try diags.addFmt(ctx.gpa, .err, .whole(value.relative_dir), 1, "", "the build could not be released; its candidate was kept for a retry: {s}", .{@errorName(err)});
        return error.IoFailed;
    };
    value.freeMemory(ctx.gpa);
    _ = ctx.state.pool.remove(handle);
}

/// Validates the current drafts through the package compiler but never publishes a build.
/// Source files may be dirty; disk assets and every on-disk baseline must still be current.
pub fn validate(ctx: Context, expected_revision: u64, diags: *Diagnostics) Error!void {
    try begin(ctx, expected_revision);
    const output_root = ctx.output_root.?;
    var lock = if (ctx.write_granted)
        save.Lock.acquire(ctx.gpa, ctx.os, ctx.source_root, expected_revision, diags) catch |err| return mapLockError(err)
    else
        save.Lock.unheld;
    defer releaseLock(ctx.gpa, &lock, diags);

    const candidate = try createCandidate(ctx, output_root);
    defer {
        cleanupCandidate(ctx, output_root, candidate.relative, diags);
        ctx.gpa.free(candidate.absolute);
        ctx.gpa.free(candidate.relative);
    }

    var product = try compileCandidate(ctx, candidate.absolute, true, diags);
    product.deinit(ctx.gpa);
}

/// Builds only a clean saved snapshot and publishes a generational build handle after the
/// candidate passes the ordinary content loader.
pub fn build(ctx: Context, expected_revision: u64, diags: *Diagnostics) Error!Handle {
    try begin(ctx, expected_revision);
    if (ctx.state.pool.count() >= ctx.limits.max_live_builds) return error.BuildLimit;
    for (ctx.documents) |document| {
        if (!document.on_disk or document.dirty()) return error.DirtyDocuments;
        if (document.externally_changed) return error.ExternalChange;
    }
    try ctx.state.pool.ensureUnusedCapacity(ctx.gpa, 1);

    const output_root = ctx.output_root.?;
    var lock = if (ctx.write_granted)
        save.Lock.acquire(ctx.gpa, ctx.os, ctx.source_root, expected_revision, diags) catch |err| return mapLockError(err)
    else
        save.Lock.unheld;
    defer releaseLock(ctx.gpa, &lock, diags);

    const candidate = try createCandidate(ctx, output_root);
    var keep = false;
    var keep_relative = false;
    defer {
        if (!keep) cleanupCandidate(ctx, output_root, candidate.relative, diags);
        ctx.gpa.free(candidate.absolute);
        if (!keep_relative) ctx.gpa.free(candidate.relative);
    }

    var product = try compileCandidate(ctx, candidate.absolute, false, diags);
    errdefer product.deinit(ctx.gpa);
    const relative_owned = candidate.relative;
    errdefer ctx.gpa.free(relative_owned);
    const handle = ctx.state.pool.add(ctx.gpa, .{
        .relative_dir = relative_owned,
        .identity = product.identity,
        .package_bytes = product.package_bytes,
        .revision = expected_revision,
    }) catch unreachable; // capacity was reserved before any filesystem mutation
    product.transferred = true;
    keep = true;
    keep_relative = true;
    return handle;
}

fn begin(ctx: Context, expected_revision: u64) Error!void {
    if (!ctx.build_granted) return error.BuildNotGranted;
    if (ctx.output_root == null) return error.OutputUnavailable;
    if (expected_revision != ctx.revision) return error.StaleRevision;
    if (ctx.limits.max_live_builds == 0) return error.BuildLimit;
}

const Candidate = struct { relative: []u8, absolute: []u8 };

fn createCandidate(ctx: Context, output_root: []const u8) Error!Candidate {
    var attempt: u32 = 0;
    while (attempt < 8) : (attempt += 1) {
        ctx.sequence.* +%= 1;
        const relative = try std.fmt.allocPrint(ctx.gpa, ".foundry-build-{x}-{x}", .{
            @as(u64, @bitCast(ctx.os.wallClockNanos())),
            ctx.sequence.*,
        });
        errdefer ctx.gpa.free(relative);
        ctx.os.createDirConfined(output_root, relative) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AlreadyExists => {
                ctx.gpa.free(relative);
                continue;
            },
            else => return error.IoFailed,
        };
        const absolute = platform.os.joinPath(ctx.gpa, &.{ output_root, relative }) catch {
            ctx.os.deleteTreeConfined(output_root, relative) catch {};
            return error.OutOfMemory;
        };
        return .{ .relative = relative, .absolute = absolute };
    }
    return error.IoFailed;
}

const Product = struct {
    identity: compiler.Identity,
    package_bytes: []u8,
    transferred: bool = false,

    fn deinit(self: *Product, gpa: Allocator) void {
        if (!self.transferred) {
            gpa.free(self.identity.name);
            gpa.free(self.package_bytes);
        }
        self.* = undefined;
    }
};

fn compileCandidate(ctx: Context, candidate_root: []const u8, use_drafts: bool, diags: *Diagnostics) Error!Product {
    for ([_][]const u8{ "source", "runtime", "runtime/assets", "generated", "dependencies" }) |dir|
        ctx.os.createDirPathConfined(candidate_root, dir) catch return error.IoFailed;

    var budget: usize = 0;
    var walk_arena: core.Arena = .init(ctx.gpa);
    defer walk_arena.deinit();
    var walk = compiler.Walk.run(ctx.gpa, walk_arena.allocator(), ctx.os, ctx.source_root, ctx.limits.walk, diags) catch |err| return mapCompilerError(err);
    defer walk.deinit(ctx.gpa);
    try checkSourceInventory(ctx, &walk, diags);

    // Source documents come from drafts for Validate and from equal saved baselines for Build.
    for (ctx.documents) |*document| {
        if (document.on_disk) try checkDocumentDisk(ctx, document, diags);
        const bytes = if (use_drafts) document.bytes else document.baseline;
        try account(&budget, bytes.len, ctx.limits.max_snapshot_bytes);
        const source_path = try prefixed(ctx.gpa, "source", document.path);
        defer ctx.gpa.free(source_path);
        try writeNew(ctx, candidate_root, source_path, bytes);
    }

    // Ordinary assets are both compiler inputs and runtime products. Authoring-format grids
    // are inputs only; the compiler emits their `.fgrid` products into `generated`.
    for (walk.assets.items) |path| {
        const read = try readSnapshotFile(ctx, ctx.source_root, path, &budget);
        defer ctx.gpa.free(read);
        const source_path = try prefixed(ctx.gpa, "source", path);
        defer ctx.gpa.free(source_path);
        try writeNew(ctx, candidate_root, source_path, read);
        const runtime_path = try prefixed(ctx.gpa, "runtime/assets", path);
        defer ctx.gpa.free(runtime_path);
        try writeNew(ctx, candidate_root, runtime_path, read);
    }
    for (walk.grids.items) |path| {
        const read = try readSnapshotFile(ctx, ctx.source_root, path, &budget);
        defer ctx.gpa.free(read);
        const source_path = try prefixed(ctx.gpa, "source", path);
        defer ctx.gpa.free(source_path);
        try writeNew(ctx, candidate_root, source_path, read);
    }

    const dep_sources = try snapshotDependencies(ctx, candidate_root, &budget, diags);
    defer {
        for (dep_sources) |source| {
            ctx.gpa.free(source.path);
            if (source.assets_root) |root| ctx.gpa.free(root);
        }
        ctx.gpa.free(dep_sources);
    }

    // Re-read the complete relevant inventory after capture. Later source changes cannot
    // mix generations because compilation below reads only `candidate_root/source`.
    try verifyLocalSnapshot(ctx, candidate_root, &walk, diags);
    try verifyDependencySnapshot(ctx, candidate_root, diags);

    var captured_dependencies = dependency.Set.load(ctx.gpa, ctx.os, dep_sources, ctx.limits.dependencies, diags) catch |err| return mapDependencyError(err);
    defer captured_dependencies.deinit();

    const source_root = platform.os.joinPath(ctx.gpa, &.{ candidate_root, "source" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IoFailed,
    };
    defer ctx.gpa.free(source_root);
    const generated_root = platform.os.joinPath(ctx.gpa, &.{ candidate_root, "generated" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IoFailed,
    };
    defer ctx.gpa.free(generated_root);

    var registry = data.Registry.init(ctx.gpa, ctx.limits.content);
    defer registry.deinit(ctx.gpa);
    var package: std.ArrayList(u8) = .empty;
    defer package.deinit(ctx.gpa);
    const identity = compiler.compile(ctx.gpa, ctx.os, source_root, .{
        .limits = ctx.limits.content,
        .max_source_bytes = ctx.limits.max_source_bytes,
        .assets_out = generated_root,
        .dependencies = &captured_dependencies,
        .walk = ctx.limits.walk,
    }, &registry, diags, &package) catch |err| return mapCompilerError(err);
    errdefer ctx.gpa.free(identity.name);

    try mergeGenerated(ctx, candidate_root, &budget);
    try account(&budget, package.items.len, ctx.limits.max_snapshot_bytes);
    try writeNew(ctx, candidate_root, "runtime/package.fpk", package.items);
    try validateLoad(ctx, package.items, &captured_dependencies, diags);

    return .{
        .identity = identity,
        .package_bytes = try package.toOwnedSlice(ctx.gpa),
    };
}

fn checkSourceInventory(ctx: Context, walk: *const compiler.Walk, diags: *Diagnostics) Error!void {
    var disk_count: usize = 0;
    for (ctx.documents) |document| disk_count += @intFromBool(document.on_disk);
    if (walk.sources.items.len != disk_count) {
        try diags.addFmt(ctx.gpa, .err, .whole("."), 1, "", "the source-file inventory changed after the workspace opened; refresh before validating or building", .{});
        return error.ExternalChange;
    }
    for (walk.sources.items) |path| {
        const document = findDocument(ctx.documents, path) orelse {
            try diags.addFmt(ctx.gpa, .err, .whole(path), 1, "", "appeared after the workspace opened; refresh before validating or building", .{});
            return error.ExternalChange;
        };
        if (!document.on_disk) return error.ExternalChange;
    }
}

fn checkDocumentDisk(ctx: Context, document: *Document, diags: *Diagnostics) Error!void {
    const read = ctx.os.readFileConfined(ctx.gpa, ctx.source_root, document.path, ctx.limits.max_source_bytes) catch |err| {
        document.externally_changed = true;
        try diags.addFmt(ctx.gpa, .err, .whole(document.path), 1, "", "changed while the workspace was open: {s}", .{@errorName(err)});
        return error.ExternalChange;
    };
    defer ctx.gpa.free(read.bytes);
    if (!std.mem.eql(u8, read.bytes, document.baseline)) {
        document.externally_changed = true;
        try diags.addFmt(ctx.gpa, .err, .whole(document.path), 1, "", "changed outside the workspace; refresh before validating or building", .{});
        return error.ExternalChange;
    }
}

fn verifyLocalSnapshot(ctx: Context, candidate_root: []const u8, first: *const compiler.Walk, diags: *Diagnostics) Error!void {
    var arena: core.Arena = .init(ctx.gpa);
    defer arena.deinit();
    var again = compiler.Walk.run(ctx.gpa, arena.allocator(), ctx.os, ctx.source_root, ctx.limits.walk, diags) catch |err| return mapCompilerError(err);
    defer again.deinit(ctx.gpa);
    if (!samePaths(first.sources.items, again.sources.items) or
        !samePaths(first.assets.items, again.assets.items) or
        !samePaths(first.grids.items, again.grids.items))
    {
        try diags.addFmt(ctx.gpa, .err, .whole("."), 1, "", "the package inventory changed while its build snapshot was being captured", .{});
        return error.ExternalChange;
    }
    for (ctx.documents) |*document| if (document.on_disk) try checkDocumentDisk(ctx, document, diags);
    for (first.assets.items) |path| try compareOriginalToSnapshot(ctx, candidate_root, ctx.source_root, path, diags);
    for (first.grids.items) |path| try compareOriginalToSnapshot(ctx, candidate_root, ctx.source_root, path, diags);
}

fn snapshotDependencies(ctx: Context, candidate_root: []const u8, budget: *usize, diags: *Diagnostics) Error![]dependency.Source {
    const packages = ctx.dependencies.items();
    const out = try ctx.gpa.alloc(dependency.Source, packages.len);
    errdefer ctx.gpa.free(out);
    var kept: usize = 0;
    errdefer for (out[0..kept]) |source| {
        ctx.gpa.free(source.path);
        if (source.assets_root) |root| ctx.gpa.free(root);
    };

    for (packages, 0..) |package, i| {
        const current = try readHostFile(ctx, package.path, ctx.limits.dependencies.max_package_bytes);
        defer ctx.gpa.free(current);
        if (!std.mem.eql(u8, current, package.bytes)) {
            try diags.addFmt(ctx.gpa, .err, .whole(package.path), 1, "", "the dependency package changed while the workspace was open", .{});
            return error.ExternalChange;
        }
        try account(budget, current.len, ctx.limits.max_snapshot_bytes);
        const rel = try std.fmt.allocPrint(ctx.gpa, "dependencies/{d}/package.fpk", .{i});
        defer ctx.gpa.free(rel);
        try writeNew(ctx, candidate_root, rel, current);
        const package_path = platform.os.joinPath(ctx.gpa, &.{ candidate_root, rel }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.IoFailed,
        };
        errdefer ctx.gpa.free(package_path);

        var asset_path: ?[]u8 = null;
        errdefer if (asset_path) |path| ctx.gpa.free(path);
        if (package.assets_root) |root| {
            const dep_assets_rel = try std.fmt.allocPrint(ctx.gpa, "dependencies/{d}/assets", .{i});
            defer ctx.gpa.free(dep_assets_rel);
            ctx.os.createDirPathConfined(candidate_root, dep_assets_rel) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.IoFailed,
            };
            var tree = try FileTree.run(ctx, root, diags);
            defer tree.deinit(ctx.gpa);
            for (tree.files) |path| {
                const read = try readSnapshotFile(ctx, root, path, budget);
                defer ctx.gpa.free(read);
                const dest = try std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ dep_assets_rel, path });
                defer ctx.gpa.free(dest);
                try writeNew(ctx, candidate_root, dest, read);
            }
            asset_path = platform.os.joinPath(ctx.gpa, &.{ candidate_root, dep_assets_rel }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.IoFailed,
            };
        }
        out[i] = .{ .path = package_path, .assets_root = asset_path };
        kept += 1;
    }
    return out;
}

fn verifyDependencySnapshot(ctx: Context, candidate_root: []const u8, diags: *Diagnostics) Error!void {
    for (ctx.dependencies.items(), 0..) |package, i| {
        const current = try readHostFile(ctx, package.path, ctx.limits.dependencies.max_package_bytes);
        defer ctx.gpa.free(current);
        if (!std.mem.eql(u8, current, package.bytes)) {
            try diags.addFmt(ctx.gpa, .err, .whole(package.path), 1, "", "the dependency package changed while its build snapshot was being captured", .{});
            return error.ExternalChange;
        }
        if (package.assets_root) |root| {
            var tree = try FileTree.run(ctx, root, diags);
            defer tree.deinit(ctx.gpa);
            const snapshot_root = try std.fmt.allocPrint(ctx.gpa, "dependencies/{d}/assets", .{i});
            defer ctx.gpa.free(snapshot_root);
            var captured = try FileTree.runAt(ctx, candidate_root, snapshot_root, diags);
            defer captured.deinit(ctx.gpa);
            if (!samePaths(tree.files, captured.files)) return error.ExternalChange;
            for (tree.files) |path| {
                const original = ctx.os.readFileConfined(ctx.gpa, root, path, ctx.limits.max_snapshot_bytes) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.ExternalChange,
                };
                defer ctx.gpa.free(original.bytes);
                const rel = try std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ snapshot_root, path });
                defer ctx.gpa.free(rel);
                const copy = ctx.os.readFileConfined(ctx.gpa, candidate_root, rel, ctx.limits.max_snapshot_bytes) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.IoFailed,
                };
                defer ctx.gpa.free(copy.bytes);
                if (!std.mem.eql(u8, original.bytes, copy.bytes)) return error.ExternalChange;
            }
        }
    }
}

fn mergeGenerated(ctx: Context, candidate_root: []const u8, budget: *usize) Error!void {
    var tree = try FileTree.runAt(ctx, candidate_root, "generated", null);
    defer tree.deinit(ctx.gpa);
    for (tree.files) |path| {
        const generated_rel = try std.fmt.allocPrint(ctx.gpa, "generated/{s}", .{path});
        defer ctx.gpa.free(generated_rel);
        const read = ctx.os.readFileConfined(ctx.gpa, candidate_root, generated_rel, ctx.limits.max_snapshot_bytes) catch return error.IoFailed;
        defer ctx.gpa.free(read.bytes);
        try account(budget, read.bytes.len, ctx.limits.max_snapshot_bytes);
        const runtime_rel = try std.fmt.allocPrint(ctx.gpa, "runtime/assets/{s}", .{path});
        defer ctx.gpa.free(runtime_rel);
        writeNew(ctx, candidate_root, runtime_rel, read.bytes) catch |err| switch (err) {
            error.IoFailed => return error.ContentInvalid,
            else => return err,
        };
    }
}

fn validateLoad(ctx: Context, own_bytes: []const u8, deps: *const dependency.Set, diags: *Diagnostics) Error!void {
    var arena: core.Arena = .init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var own_reader = data.fpk.Reader.open(ctx.gpa, own_bytes, ctx.limits.content) catch return error.ContentInvalid;
    defer own_reader.deinit();
    const own_manifest = mod.manifest.read(a, &own_reader) catch return error.ContentInvalid;

    const candidates = try a.alloc(mod.Candidate, deps.items().len + 1);
    const enabled = try a.alloc(core.ContentId, deps.items().len + 1);
    for (deps.items(), 0..) |package, i| {
        candidates[i] = .{
            .manifest = package.manifest,
            .base_dir = "<candidate>",
            .file = package.path,
            .root = package.assets_root orelse "",
            .origin = .installed,
        };
        enabled[i] = package.id();
    }
    candidates[deps.items().len] = .{
        .manifest = own_manifest,
        .base_dir = "<candidate>",
        .file = "package.fpk",
        .root = "assets",
        .origin = .installed,
    };
    enabled[deps.items().len] = own_manifest.id;

    var resolution = mod.resolve(ctx.gpa, candidates, .{
        .enabled = enabled,
        .required = &.{own_manifest.id},
    }, diags) catch return error.ContentInvalid;
    defer resolution.deinit();

    var registry = data.Registry.init(ctx.gpa, ctx.limits.content);
    defer registry.deinit(ctx.gpa);
    var store = data.Store.init(ctx.gpa, ctx.limits.content);
    defer store.deinit(ctx.gpa);
    for (resolution.order) |entry| {
        const bytes = if (entry.id.eql(own_manifest.id)) own_bytes else blk: {
            const package = deps.find(entry.id) orelse return error.ContentInvalid;
            break :blk package.bytes;
        };
        _ = store.add(ctx.gpa, entry.file, bytes, &registry, diags) catch return error.ContentInvalid;
    }
}

const FileTree = struct {
    arena: core.Arena,
    files: []const []const u8 = &.{},

    fn run(ctx: Context, root: []const u8, diags: ?*Diagnostics) Error!FileTree {
        return runAt(ctx, root, "", diags);
    }

    fn runAt(ctx: Context, root: []const u8, start: []const u8, diags: ?*Diagnostics) Error!FileTree {
        var self: FileTree = .{ .arena = .init(ctx.gpa) };
        errdefer self.arena.deinit();
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(ctx.gpa);
        var seen: u32 = 0;
        try descendTree(ctx, self.arena.allocator(), root, start, "", &list, &seen, diags);
        std.mem.sort([]const u8, list.items, {}, lessPath);
        self.files = try self.arena.allocator().dupe([]const u8, list.items);
        return self;
    }

    fn deinit(self: *FileTree, _: Allocator) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn descendTree(ctx: Context, arena: Allocator, root: []const u8, base: []const u8, prefix: []const u8, files: *std.ArrayList([]const u8), seen: *u32, diags: ?*Diagnostics) Error!void {
    const depth = if (prefix.len == 0) 0 else std.mem.count(u8, prefix, "/") + 1;
    if (depth > ctx.limits.walk.max_depth) return error.SnapshotLimit;
    const at = if (base.len == 0) prefix else if (prefix.len == 0) base else try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, prefix });
    var listing = ctx.os.listDirConfined(ctx.gpa, root, at) catch |err| {
        if (diags) |d| try d.addFmt(ctx.gpa, .err, .whole(if (at.len == 0) "." else at), 1, "", "could not be snapshotted: {s}", .{@errorName(err)});
        return error.IoFailed;
    };
    defer listing.deinit();
    const entries = try ctx.gpa.dupe(platform.os.DirEntry, listing.entries);
    defer ctx.gpa.free(entries);
    std.mem.sort(platform.os.DirEntry, entries, {}, lessEntry);
    for (entries) |entry| {
        if (seen.* >= ctx.limits.walk.max_entries) return error.SnapshotLimit;
        seen.* += 1;
        const rel = if (prefix.len == 0) try arena.dupe(u8, entry.name) else try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => try descendTree(ctx, arena, root, base, rel, files, seen, diags),
            .file => try files.append(ctx.gpa, rel),
            .other => {
                if (diags) |d| try d.addFmt(ctx.gpa, .err, .whole(rel), 1, "", "is not a regular file or directory and cannot enter a build snapshot", .{});
                return error.IoFailed;
            },
        }
    }
}

fn writeNew(ctx: Context, root: []const u8, relative_owned: []const u8, bytes: []const u8) Error!void {
    if (std.fs.path.dirnamePosix(relative_owned)) |parent| ctx.os.createDirPathConfined(root, parent) catch return error.IoFailed;
    _ = ctx.os.createFileConfined(root, relative_owned, bytes, ctx.limits.max_snapshot_bytes) catch return error.IoFailed;
}

fn prefixed(gpa: Allocator, prefix: []const u8, path: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, path });
}

fn readSnapshotFile(ctx: Context, root: []const u8, path: []const u8, budget: *usize) Error![]u8 {
    const remaining = ctx.limits.max_snapshot_bytes -| budget.*;
    const read = ctx.os.readFileConfined(ctx.gpa, root, path, remaining) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileTooLarge => return error.SnapshotLimit,
        else => return error.IoFailed,
    };
    errdefer ctx.gpa.free(read.bytes);
    try account(budget, read.bytes.len, ctx.limits.max_snapshot_bytes);
    return read.bytes;
}

fn readHostFile(ctx: Context, path: []const u8, max: usize) Error![]u8 {
    const dir = std.fs.path.dirname(path) orelse ".";
    const leaf = std.fs.path.basename(path);
    const read = ctx.os.readFileConfined(ctx.gpa, dir, leaf, max) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IoFailed,
    };
    return read.bytes;
}

fn compareOriginalToSnapshot(ctx: Context, candidate_root: []const u8, original_root: []const u8, path: []const u8, diags: *Diagnostics) Error!void {
    const original = ctx.os.readFileConfined(ctx.gpa, original_root, path, ctx.limits.max_snapshot_bytes) catch return error.ExternalChange;
    defer ctx.gpa.free(original.bytes);
    const rel = try prefixed(ctx.gpa, "source", path);
    defer ctx.gpa.free(rel);
    const captured = ctx.os.readFileConfined(ctx.gpa, candidate_root, rel, ctx.limits.max_snapshot_bytes) catch return error.IoFailed;
    defer ctx.gpa.free(captured.bytes);
    if (!std.mem.eql(u8, original.bytes, captured.bytes)) {
        try diags.addFmt(ctx.gpa, .err, .whole(path), 1, "", "changed while its build snapshot was being captured", .{});
        return error.ExternalChange;
    }
}

fn account(total: *usize, amount: usize, max: usize) Error!void {
    total.* = std.math.add(usize, total.*, amount) catch return error.SnapshotLimit;
    if (total.* > max) return error.SnapshotLimit;
}

fn samePaths(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}

fn findDocument(documents: []Document, path: []const u8) ?*Document {
    for (documents) |*document| if (std.mem.eql(u8, document.path, path)) return document;
    return null;
}

fn lessPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn lessEntry(_: void, a: platform.os.DirEntry, b: platform.os.DirEntry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn mapCompilerError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ContentInvalid => error.ContentInvalid,
        error.OverBudget => error.SnapshotLimit,
        else => error.IoFailed,
    };
}

fn mapDependencyError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ContentInvalid => error.ContentInvalid,
        error.OverBudget => error.SnapshotLimit,
        else => error.IoFailed,
    };
}

fn mapLockError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Busy => error.Busy,
        else => error.IoFailed,
    };
}

fn cleanupCandidate(ctx: Context, output_root: []const u8, relative: []const u8, diags: *Diagnostics) void {
    ctx.os.deleteTreeConfined(output_root, relative) catch |err|
        diags.addFmt(ctx.gpa, .warning, .whole(relative), 1, "", "an incomplete private build could not be removed: {s}", .{@errorName(err)}) catch {};
}

fn releaseLock(gpa: Allocator, lock: *save.Lock, diags: *Diagnostics) void {
    if (!lock.release()) diags.addFmt(gpa, .warning, .whole(save.lock_file), 1, "", "the operation finished but its workspace lock could not be removed safely; recover it manually after confirming no editor owns it", .{}) catch {};
}
