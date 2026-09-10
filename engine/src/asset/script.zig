//! Copied, revisioned source for `foundry:script` assets.
//!
//! This loader knows text and the declared language, not Lua. It performs no parsing or
//! execution and therefore keeps content compilation and content-only hosts independent of
//! the optional M8 runtime. The source becomes an ordinary opaque asset payload; Step 3 will
//! publish a typed copy through the public ABI without giving scripts filesystem access.
//!
//! Design: `docs/design/scripting.md` §5 and §6.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");

const registry = @import("registry.zig");
const schemas = @import("schemas.zig");

const Allocator = std.mem.Allocator;

/// The step-2 source bound, applied by the asset registry before it allocates or reads the
/// file. This is separate from the later Lua heap quota.
pub const max_source_bytes: usize = 256 << 10;

pub const Source = struct {
    bytes: []u8,
    /// Nonzero and monotonic for one loader instance. A replacement receives a new value;
    /// a failed load never replaces the previous payload.
    revision: u64,
};

/// Owns the revision sequence and supplies the runtime-registered loader callbacks (I6).
/// Its address must remain stable while registered because it is the loader context.
pub const SourceLoader = struct {
    next_revision: u64 = 1,

    pub fn assetLoader(self: *SourceLoader) registry.Loader {
        return .{
            .schema = schemas.script.id,
            .ctx = self,
            .max_source_bytes = max_source_bytes,
            .load = load,
            .unload = unload,
        };
    }

    fn load(ctx: ?*anyopaque, gpa: Allocator, record: data.store.Record, bytes: []const u8) registry.LoadError!registry.Payload {
        const self: *SourceLoader = @ptrCast(@alignCast(ctx orelse return error.LoadFailed));
        const language = schemas.stringField(record, schemas.script, schemas.language_field) orelse
            return error.InvalidAsset;
        if (!std.mem.eql(u8, language, schemas.script_language)) return error.UnsupportedVersion;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidAsset;
        if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidAsset;
        // Lua's portable binary-chunk signature begins with ESC. No bytecode reaches the
        // runtime even when the rest happens to be valid UTF-8.
        if (bytes.len > 0 and bytes[0] == 0x1b) return error.InvalidAsset;
        if (self.next_revision == 0) return error.LoadFailed;

        const made = try gpa.create(Source);
        errdefer gpa.destroy(made);
        made.* = .{
            .bytes = try gpa.dupe(u8, bytes),
            .revision = self.next_revision,
        };
        self.next_revision +%= 1;
        return .fromPointer(made);
    }

    fn unload(_: ?*anyopaque, gpa: Allocator, payload: registry.Payload) void {
        const made: *Source = @ptrCast(@alignCast(payload.pointer() orelse return));
        gpa.free(made.bytes);
        gpa.destroy(made);
    }
};

/// Returns a script source only when `loader` is the exact registered owner of the payload.
/// A matching schema or pointer-shaped word is not provenance.
pub fn get(registry_value: *registry.Registry, handle: registry.AssetHandle, loader: *SourceLoader) ?*const Source {
    const loaded = registry_value.getIfLoader(handle, loader.assetLoader()) orelse return null;
    return @ptrCast(@alignCast(loaded.payload.pointer() orelse return null));
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    os: *platform.os.Os,
    schemas_registry: data.Registry,
    diags: data.Diagnostics,
    store: data.Store,
    assets: registry.Registry,
    blobs: std.ArrayList(std.ArrayList(u8)) = .empty,
    loader: SourceLoader = .{},

    fn init() !*Fixture {
        const gpa = testing.allocator;
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);
        self.* = .{
            .tmp = testing.tmpDir(.{}),
            .os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-script-source-test" }),
            .schemas_registry = .init(gpa, .default),
            .diags = .init(gpa, .default),
            .store = .init(gpa, .default),
            .assets = undefined,
        };
        const n = try self.tmp.dir.realPath(testing.io, &self.root_buf);
        self.root = self.root_buf[0..n];
        self.assets = .init(gpa, self.os, &self.store, .{});
        try schemas.registerAll(gpa, &self.schemas_registry);
        try self.assets.registerLoader(gpa, self.loader.assetLoader());
        return self;
    }

    fn deinit(self: *Fixture) void {
        const gpa = testing.allocator;
        self.assets.deinit(gpa);
        self.store.deinit(gpa);
        self.schemas_registry.deinit(gpa);
        self.diags.deinit(gpa);
        for (self.blobs.items) |*blob| blob.deinit(gpa);
        self.blobs.deinit(gpa);
        self.os.deinit();
        self.tmp.cleanup();
        gpa.destroy(self);
    }

    fn write(self: *Fixture, relative: []const u8, bytes: []const u8) !void {
        const path = try platform.os.joinPath(testing.allocator, &.{ self.root, relative });
        defer testing.allocator.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.os.createDirPath(parent);
        try self.os.writeFile(path, bytes);
    }

    fn addPackage(self: *Fixture, name: []const u8, source_text: []const u8) !void {
        const colon = std.mem.indexOfScalar(u8, name, ':').?;
        var doc = try data.parser.parse(testing.allocator, "scripts.fdt", source_text, .{
            .namespace = name[0..colon],
        }, &self.diags);
        defer doc.deinit(testing.allocator);

        var package = try data.check.Package.init(testing.allocator, name, 1, .default);
        defer package.deinit(testing.allocator);
        try package.addDocument(testing.allocator, &doc, &self.schemas_registry, &self.diags);

        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(testing.allocator);
        try data.fpk.write(testing.allocator, &package, &self.schemas_registry, &bytes);
        try self.blobs.append(testing.allocator, bytes);
        const handle = try self.store.add(
            testing.allocator,
            name,
            self.blobs.items[self.blobs.items.len - 1].items,
            &self.schemas_registry,
            &self.diags,
        );
        try self.assets.mount(testing.allocator, handle, self.root);
    }
};

test "script source is copied, revisioned, and failed replacement preserves the winner" {
    const fx = try Fixture.init();
    defer fx.deinit();
    try fx.write("scripts/main.lua", "return 1");
    try fx.addPackage("example:base",
        \\foundry:script example:scripts.main { source "scripts/main.lua" language "lua-5.5" }
    );

    const id = core.ContentId.fromString("example:scripts.main");
    const handle = try fx.assets.acquireOf(testing.allocator, id, schemas.script.id);
    defer fx.assets.release(handle);
    try testing.expectEqualStrings("return 1", get(&fx.assets, handle, &fx.loader).?.bytes);
    try testing.expectEqual(@as(u64, 1), get(&fx.assets, handle, &fx.loader).?.revision);

    var other: SourceLoader = .{};
    try testing.expect(get(&fx.assets, handle, &other) == null);

    try fx.write("scripts/main.lua", "return 2");
    try fx.assets.reload(testing.allocator, handle);
    try testing.expectEqualStrings("return 2", get(&fx.assets, handle, &fx.loader).?.bytes);
    try testing.expectEqual(@as(u64, 2), get(&fx.assets, handle, &fx.loader).?.revision);

    try fx.write("scripts/main.lua", "bad\x00source");
    try testing.expectError(error.InvalidAsset, fx.assets.reload(testing.allocator, handle));
    try testing.expectEqualStrings("return 2", get(&fx.assets, handle, &fx.loader).?.bytes);
    try testing.expectEqual(@as(u64, 2), get(&fx.assets, handle, &fx.loader).?.revision);

    try fx.write("override.lua", "return 3");
    try fx.addPackage("example:override",
        \\foundry:script example:scripts.main { source "override.lua" language "lua-5.5" }
    );
    try fx.assets.reload(testing.allocator, handle);
    try testing.expectEqualStrings("return 3", get(&fx.assets, handle, &fx.loader).?.bytes);
    try testing.expectEqual(@as(u64, 3), get(&fx.assets, handle, &fx.loader).?.revision);
}

test "script source rejects language, binary text, symlinks, and oversized files before loading" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const fx = try Fixture.init();
    defer fx.deinit();
    try fx.write("scripts/plain.lua", "return 1");
    try fx.write("scripts/nul.lua", "a\x00b");
    try fx.write("scripts/utf8.lua", "\xff");
    try fx.write("scripts/bytecode.lua", "\x1bLua");
    try fx.write("scripts/large.lua", "x" ** (max_source_bytes + 1));
    try fx.tmp.dir.symLink(testing.io, "plain.lua", "scripts/link.lua", .{});
    try fx.addPackage("bad:assets",
        \\foundry:script bad:wrong_language { source "scripts/plain.lua" language "lua-5.4" }
        \\foundry:script bad:nul            { source "scripts/nul.lua" language "lua-5.5" }
        \\foundry:script bad:utf8           { source "scripts/utf8.lua" language "lua-5.5" }
        \\foundry:script bad:bytecode       { source "scripts/bytecode.lua" language "lua-5.5" }
        \\foundry:script bad:large          { source "scripts/large.lua" language "lua-5.5" }
        \\foundry:script bad:link           { source "scripts/link.lua" language "lua-5.5" }
    );

    try testing.expectError(error.UnsupportedVersion, fx.assets.acquire(testing.allocator, core.ContentId.fromString("bad:wrong_language")));
    inline for (.{ "bad:nul", "bad:utf8", "bad:bytecode" }) |name| {
        try testing.expectError(error.InvalidAsset, fx.assets.acquire(testing.allocator, core.ContentId.fromString(name)));
    }
    try testing.expectError(error.LoadFailed, fx.assets.acquire(testing.allocator, core.ContentId.fromString("bad:large")));
    try testing.expectEqual(@as(u64, 1), fx.loader.next_revision);
    try testing.expectError(error.SourceRejected, fx.assets.acquire(testing.allocator, core.ContentId.fromString("bad:link")));
    try testing.expectEqual(@as(u32, 0), fx.assets.count());
}

test "script source revision exhaustion refuses replacement instead of wrapping" {
    const fx = try Fixture.init();
    defer fx.deinit();
    fx.loader.next_revision = std.math.maxInt(u64);
    try fx.write("main.lua", "return 1");
    try fx.addPackage("revision:test",
        \\foundry:script revision:main { source "main.lua" language "lua-5.5" }
    );
    const handle = try fx.assets.acquire(testing.allocator, core.ContentId.fromString("revision:main"));
    defer fx.assets.release(handle);
    try testing.expectEqual(std.math.maxInt(u64), get(&fx.assets, handle, &fx.loader).?.revision);

    try fx.write("main.lua", "return 2");
    try testing.expectError(error.LoadFailed, fx.assets.reload(testing.allocator, handle));
    try testing.expectEqualStrings("return 1", get(&fx.assets, handle, &fx.loader).?.bytes);
    try testing.expectEqual(std.math.maxInt(u64), get(&fx.assets, handle, &fx.loader).?.revision);
}
