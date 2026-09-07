//! A stand-in engine, for testing the boundary without one.
//!
//! `Host` is generic over the engine's type precisely so that this can exist: `app.Engine`
//! is `EngineOf(platform.Platform, rhi.Device)`, and a boundary test that had to open a
//! window and a device in order to read a record would be measuring the machine. Everything
//! here is a value or a real, headless subsystem — the content store and the schema registry
//! are the engine's own types, because those are what the calls actually read.
//!
//! It answers exactly the calls `HostOf` requires of an engine, which doubles as the written
//! form of that requirement: a capability added to the table that needs something new from
//! the engine fails to compile here first.

const std = @import("std");
const asset = @import("asset");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");

const Allocator = std.mem.Allocator;

/// Phantom tag for this engine's memory handles. Deliberately **not** `app.Memories`: the
/// host has to work with whatever handle type an engine hands back, and the only way to know
/// that is true is to hand it a different one.
pub const Memories = opaque {};
pub const MemoryHandle = core.Handle(Memories);

pub const TestEngine = struct {
    const Self = @This();

    frame_index: u64 = 0,
    step_delta: core.time.Duration = .{ .ns = 16_666_666 },
    frame_delta: core.time.Duration = .{ .ns = 16_000_000 },
    total_elapsed: core.time.Duration = .zero,

    store: data.Store,
    schemas: data.Registry,
    assets: asset.Registry,
    diags: data.Diagnostics,
    /// The registry needs one, and a headless `Os` costs a heap allocation and nothing else:
    /// no window, no display server, no environment beyond what it is handed.
    os: *platform.os.Os,
    /// A directory of this engine's own, for the tests that need an asset to have bytes.
    /// Created lazily, because most of them do not.
    dir: ?[]u8 = null,
    /// Bumped by `reloadContent`, so a test can prove that a view opened before a reload
    /// fails to resolve after one.
    content_generation: u64 = 0,
    /// The compiled bytes of every package added, kept alive because the store reads records
    /// **in place** out of them — the same reason `app.Engine` keeps its own.
    blobs: std.ArrayList([]u8) = .empty,

    arena: core.Arena,

    counters: core.HandlePool(Memories, *core.mem.Counted) = .empty,
    /// How many spans are open, so a test can assert the pairing the boundary claims.
    open_scopes: u32 = 0,
    /// Names in the order they were opened, so a test can see what the profiler was told.
    scope_names: std.ArrayList([]const u8) = .empty,

    gpa: Allocator,

    pub fn init(gpa: Allocator) !Self {
        const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-abi-test", .env = &.{} });
        errdefer os.deinit();

        var self: Self = .{
            .store = .init(gpa, .default),
            .schemas = .init(gpa, .default),
            .assets = undefined,
            .diags = .init(gpa, .default),
            .os = os,
            .arena = .init(gpa),
            .gpa = gpa,
        };
        self.assets = .init(gpa, os, &self.store, .{});
        return self;
    }

    /// The registry borrows a pointer to the store, so a `TestEngine` that has been moved
    /// since `init` is holding one into wherever it used to be. Every fixture allocates it
    /// and leaves it there; this is the call that fixes up a value built on the stack.
    pub fn settle(self: *Self) void {
        self.assets = .init(self.gpa, self.os, &self.store, .{});
    }

    pub fn contentGeneration(self: *const Self) u64 {
        return self.content_generation;
    }

    /// What a hot reload does to everything derived from content: invalidates it.
    pub fn reloadContent(self: *Self) void {
        self.content_generation += 1;
    }

    pub fn deinit(self: *Self) void {
        self.scope_names.deinit(self.gpa);
        self.counters.deinit(self.gpa);
        self.arena.deinit();
        self.assets.deinit(self.gpa);
        if (self.dir) |d| self.gpa.free(d);
        self.os.deinit();
        self.store.deinit(self.gpa);
        self.schemas.deinit(self.gpa);
        self.diags.deinit(self.gpa);
        for (self.blobs.items) |b| self.gpa.free(b);
        self.blobs.deinit(self.gpa);
    }

    /// Compiles a package from `.fdt` source and merges it, exactly as the engine does.
    ///
    /// Real content rather than a stub store, because what the content calls are worth is
    /// what they answer about a record somebody wrote — and the whole pipeline from text to
    /// merged record is already hermetic (`data` cannot open a file), so there is nothing to
    /// fake.
    pub fn loadPackage(self: *Self, name: []const u8, source: []const u8) !data.store.PackageHandle {
        const colon = std.mem.indexOfScalar(u8, name, ':').?;

        var doc = try data.parser.parse(self.gpa, "test.fdt", source, .{
            .namespace = name[0..colon],
        }, &self.diags);
        defer doc.deinit(self.gpa);

        var pkg = try data.check.Package.init(self.gpa, name, 1, .default);
        defer pkg.deinit(self.gpa);
        try pkg.addDocument(self.gpa, &doc, &self.schemas, &self.diags);

        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(self.gpa);
        try data.fpk.write(self.gpa, &pkg, &self.schemas, &bytes);

        const owned = try bytes.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(owned);
        try self.blobs.append(self.gpa, owned);

        return self.store.add(self.gpa, name, owned, &self.schemas, &self.diags);
    }

    /// A directory of this engine's own, made on first use.
    pub fn contentDir(self: *Self) ![]const u8 {
        if (self.dir) |d| return d;

        const temp = try self.os.tempDirAlloc(self.gpa);
        defer self.gpa.free(temp);

        var name_buf: [64]u8 = undefined;
        const unique = std.fmt.bufPrint(&name_buf, "foundry-abi-{d}", .{std.testing.random_seed}) catch unreachable;
        const dir = try platform.os.joinPath(self.gpa, &.{ temp, unique });
        errdefer self.gpa.free(dir);
        try self.os.createDirPath(dir);

        self.dir = dir;
        return dir;
    }

    /// Writes a file a record's `source` can name, and mounts the package over it.
    pub fn writeSource(self: *Self, package: data.store.PackageHandle, rel: []const u8, bytes: []const u8) !void {
        const dir = try self.contentDir();
        const path = try platform.os.joinPath(self.gpa, &.{ dir, rel });
        defer self.gpa.free(path);
        try self.os.writeFile(path, bytes);
        try self.assets.mount(self.gpa, package, dir);
    }

    pub fn frameDelta(self: *const Self) core.time.Duration {
        return self.frame_delta;
    }

    pub fn elapsed(self: *const Self) core.time.Duration {
        return self.total_elapsed;
    }

    pub fn frameAllocator(self: *Self) Allocator {
        return self.arena.allocator();
    }

    pub fn beginScope(self: *Self, name: []const u8) Scope {
        self.open_scopes += 1;
        self.scope_names.append(self.gpa, name) catch {};
        return .{ .engine = self };
    }

    pub const Scope = struct {
        engine: *Self,

        pub fn end(self: Scope) void {
            self.engine.endScope();
        }
    };

    pub fn endScope(self: *Self) void {
        if (self.open_scopes > 0) self.open_scopes -= 1;
    }

    pub fn registerMemory(self: *Self, counter: *core.mem.Counted) Allocator.Error!MemoryHandle {
        return self.counters.add(self.gpa, counter);
    }

    pub fn unregisterMemory(self: *Self, handle: MemoryHandle) void {
        _ = self.counters.remove(handle);
    }

    /// One counter, as the memory report would see it. Enough to assert that what a mod
    /// published actually reaches the report.
    pub fn counterNamed(self: *Self, name: []const u8) ?*core.mem.Counted {
        var it = self.counters.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value.*.name, name)) return entry.value.*;
        }
        return null;
    }

    pub fn registeredCount(self: *const Self) u32 {
        return self.counters.count();
    }
};
