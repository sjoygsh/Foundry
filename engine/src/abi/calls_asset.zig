//! Assets, as the table publishes them.
//!
//! Six calls, and one of them is the only thing in `_v1` a mod has to balance:
//! **`asset_acquire` adds a reference and `asset_release` takes it away**. That is the one
//! refcount a mod owns and must own — nothing else here transfers ownership in either
//! direction, and an asset acquired and never released stays in memory for the life of the
//! process, which is stated plainly rather than swept up by something clever.
//!
//! An asset's identity is its content id, never its path (ADR-0021). Nothing here takes a
//! path, and that is what lets a mod's directory layout be its own business and a mod
//! overriding a texture not have to mirror somebody else's folders.
//!
//! Design: `docs/design/public-abi.md` §9; `docs/design/assets.md`.

const std = @import("std");
const asset = @import("asset");

const types = @import("types.zig");

const Asset = types.Asset;
const ContentId = types.ContentId;
const Cursor = types.Cursor;
const Result = types.Result;
const SchemaId = types.SchemaId;

pub fn Of(comptime H: type) type {
    return struct {
        /// Loads the asset if it is not loaded, and adds a reference either way.
        pub fn assetAcquire(id: ContentId, out: ?*Asset) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            if (id.isNone()) return .invalid_argument;

            const handle = engine.assets.acquire(engine.gpa, id) catch |err| return acquireFailure(err);
            dst.* = .wrap(handle);
            return .ok;
        }

        pub fn assetRelease(handle: Asset) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;

            // Resolved before it is released, so that a handle nobody issued is a refusal
            // rather than a silent no-op — the difference between a mod being told it has a
            // bug and a mod leaking every asset it ever acquired.
            _ = engine.assets.refCount(handle.unwrap(asset.AssetHandle)) orelse return .invalid_handle;
            engine.assets.release(handle.unwrap(asset.AssetHandle));
            return .ok;
        }

        /// One already loaded, without acquiring it.
        pub fn assetFind(id: ContentId, out: ?*Asset) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            if (id.isNone()) return .invalid_argument;

            const handle = engine.assets.find(id) orelse return .not_found;
            dst.* = .wrap(handle);
            return .ok;
        }

        /// Every loaded asset, in handle-slot order.
        ///
        /// The walk's generation is how many assets are loaded, so a walk that spans a load
        /// or an eviction is refused rather than quietly resynchronised onto whatever now
        /// occupies the slot. A reader that wants a fixed order sorts its own copy — the same
        /// sentence the registry already tells the debug overlay.
        pub fn assetNext(cursor: ?*Cursor, out: ?*Asset) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;

            const generation = engine.assets.count();
            if (generation == 0) return .end;
            if (!c.isBegin() and c.generation() != generation) return .invalid_argument;

            var it: asset.Registry.Iterator = .{ .registry = &engine.assets, .slot = c.index() };
            const info = it.next() orelse return .end;
            dst.* = .wrap(info.handle);
            c.* = .at(generation, it.slot);
            return .ok;
        }

        pub fn assetContentId(handle: Asset, out: ?*ContentId) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;

            const loaded = engine.assets.get(handle.unwrap(asset.AssetHandle)) orelse return .invalid_handle;
            dst.* = loaded.id;
            return .ok;
        }

        pub fn assetSchema(handle: Asset, out: ?*SchemaId) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;

            const loaded = engine.assets.get(handle.unwrap(asset.AssetHandle)) orelse return .invalid_handle;
            dst.* = loaded.schema_id;
            return .ok;
        }

        /// Zero means evictable, not freed — a real answer to "why is this still in memory".
        pub fn assetRefcount(handle: Asset, out: ?*u32) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;

            dst.* = engine.assets.refCount(handle.unwrap(asset.AssetHandle)) orelse return .invalid_handle;
            return .ok;
        }
    };
}

/// Why an acquire failed, in the vocabulary the boundary has.
///
/// The distinctions `asset` draws are kept where the boundary has a code for them, because
/// each one is a different fix: `not_found` is a content id nothing declares, `unsupported`
/// is a package this build cannot read, and `unavailable` is a loader the host never
/// registered — which for a mod usually means the subsystem it wanted is not in this game.
fn acquireFailure(err: asset.AcquireError) Result {
    return switch (err) {
        error.AssetNotFound, error.SourceMissing => .not_found,
        error.WrongSchema, error.SourceRejected => .invalid_argument,
        error.NoLoader => .unavailable,
        error.UnsupportedVersion => .unsupported,
        error.InvalidAsset => .invalid_argument,
        error.LoadFailed => .internal,
        error.OutOfMemory => .out_of_memory,
    };
}

comptime {
    _ = std;
}

// == Tests =============================================================================

const core = @import("core");
const data = @import("data");
const testing = std.testing;

const api = @import("api.zig");
const host_mod = @import("host.zig");
const test_engine = @import("test_engine.zig");

const TestEngine = test_engine.TestEngine;
const Host = host_mod.HostOf(TestEngine);
const table = api.TableOf(Host).v1;

/// A record type whose bytes live in a file, which is all `asset` requires of one: a
/// `source` field naming a path inside the package. Nothing here is an engine asset kind,
/// because a mod's own kind is the case worth testing.
const source_text =
    \\@schema blob { source string }
    \\blob mymod:blob.one { source "one.bin" }
    \\blob mymod:blob.two { source "two.bin" }
;

/// Counts what it was asked to load, and holds no memory, so a test can assert the refcount
/// without also asserting an allocator.
const CountingLoader = struct {
    loads: u32 = 0,
    unloads: u32 = 0,

    fn load(ctx: ?*anyopaque, _: std.mem.Allocator, _: data.store.Record, bytes: []const u8) asset.LoadError!asset.Payload {
        const self: *CountingLoader = @ptrCast(@alignCast(ctx.?));
        self.loads += 1;
        return .{ .bits = bytes.len };
    }

    fn unload(ctx: ?*anyopaque, _: std.mem.Allocator, _: asset.Payload) void {
        const self: *CountingLoader = @ptrCast(@alignCast(ctx.?));
        self.unloads += 1;
    }
};

const Fixture = struct {
    engine: TestEngine,
    host: Host,
    loader: CountingLoader = .{},

    fn init() !*Fixture {
        const self = try testing.allocator.create(Fixture);
        self.* = .{ .engine = try .init(testing.allocator), .host = .{} };
        self.engine.settle();
        self.host.engine = &self.engine;
        self.host.bind();

        const package = try self.engine.loadPackage("mymod:content", source_text);
        try self.engine.writeSource(package, "one.bin", "aaaa");
        try self.engine.writeSource(package, "two.bin", "bb");
        try self.engine.assets.registerLoader(testing.allocator, .{
            .schema = data.SchemaId.fromStringUnchecked("mymod:blob"),
            .ctx = &self.loader,
            .load = CountingLoader.load,
            .unload = CountingLoader.unload,
        });
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.host.unbind();
        self.engine.deinit();
        testing.allocator.destroy(self);
    }
};

test "a mod acquires an asset by content id, and the reference is its own to give back" {
    const f = try Fixture.init();
    defer f.deinit();

    const one = core.ContentId.fromString("mymod:blob.one");
    var handle: Asset = .none;
    try testing.expectEqual(Result.ok, table.asset_acquire(one, &handle));
    try testing.expect(!handle.isNone());
    try testing.expectEqual(@as(u32, 1), f.loader.loads);

    var refs: u32 = 0;
    try testing.expectEqual(Result.ok, table.asset_refcount(handle, &refs));
    try testing.expectEqual(@as(u32, 1), refs);

    // Acquiring again shares the load and adds a reference, which is what makes a texture
    // used by two mods loaded once.
    var again: Asset = .none;
    try testing.expectEqual(Result.ok, table.asset_acquire(one, &again));
    try testing.expectEqual(handle.bits, again.bits);
    try testing.expectEqual(@as(u32, 1), f.loader.loads);
    try testing.expectEqual(Result.ok, table.asset_refcount(handle, &refs));
    try testing.expectEqual(@as(u32, 2), refs);

    try testing.expectEqual(Result.ok, table.asset_release(handle));
    try testing.expectEqual(Result.ok, table.asset_release(handle));
    try testing.expectEqual(Result.ok, table.asset_refcount(handle, &refs));
    // Zero means evictable, not freed — which is a real answer to "why is this still here".
    try testing.expectEqual(@as(u32, 0), refs);
    try testing.expectEqual(@as(u32, 0), f.loader.unloads);
}

test "an asset says what it is, and one nobody loaded is not found" {
    const f = try Fixture.init();
    defer f.deinit();

    const one = core.ContentId.fromString("mymod:blob.one");
    var found: Asset = .none;
    try testing.expectEqual(Result.not_found, table.asset_find(one, &found));

    var handle: Asset = .none;
    try testing.expectEqual(Result.ok, table.asset_acquire(one, &handle));
    try testing.expectEqual(Result.ok, table.asset_find(one, &found));
    try testing.expectEqual(handle.bits, found.bits);

    var id: ContentId = .none;
    var schema: SchemaId = .none;
    try testing.expectEqual(Result.ok, table.asset_content_id(handle, &id));
    try testing.expectEqual(one, id);
    try testing.expectEqual(Result.ok, table.asset_schema(handle, &schema));
    try testing.expectEqual(data.SchemaId.fromStringUnchecked("mymod:blob"), schema);

    try testing.expectEqual(Result.ok, table.asset_release(handle));
}

test "the loaded assets walk, and a walk across a load is refused" {
    const f = try Fixture.init();
    defer f.deinit();

    // Nothing loaded is the end of the walk, not an error.
    var cursor: Cursor = .begin;
    var handle: Asset = .none;
    try testing.expectEqual(Result.end, table.asset_next(&cursor, &handle));

    var first: Asset = .none;
    var second: Asset = .none;
    try testing.expectEqual(Result.ok, table.asset_acquire(core.ContentId.fromString("mymod:blob.one"), &first));
    try testing.expectEqual(Result.ok, table.asset_acquire(core.ContentId.fromString("mymod:blob.two"), &second));

    cursor = .begin;
    var seen: u32 = 0;
    while (table.asset_next(&cursor, &handle) == .ok) seen += 1;
    try testing.expectEqual(@as(u32, 2), seen);

    // Half a walk, then something loads: refused rather than silently resynchronised onto
    // whatever now occupies the slot.
    cursor = .begin;
    try testing.expectEqual(Result.ok, table.asset_next(&cursor, &handle));
    var third: Asset = .none;
    const later = try f.engine.loadPackage("later:content",
        \\@schema mymod:blob { source string }
        \\mymod:blob later:blob { source "one.bin" }
    );
    try f.engine.writeSource(later, "one.bin", "aaaa");
    try testing.expectEqual(Result.ok, table.asset_acquire(core.ContentId.fromString("later:blob"), &third));
    try testing.expectEqual(Result.invalid_argument, table.asset_next(&cursor, &handle));

    try testing.expectEqual(Result.ok, table.asset_release(first));
    try testing.expectEqual(Result.ok, table.asset_release(second));
    try testing.expectEqual(Result.ok, table.asset_release(third));
}

test "every way an acquire can fail says which one it was" {
    const f = try Fixture.init();
    defer f.deinit();

    var handle: Asset = .none;

    // A content id nothing declares.
    try testing.expectEqual(Result.not_found, table.asset_acquire(core.ContentId.fromString("mymod:absent"), &handle));
    try testing.expectEqual(Result.invalid_argument, table.asset_acquire(.none, &handle));

    // A record whose `source` names a file that is not there. Different failure, different
    // fix, and worth being told apart from a record that does not exist.
    const gone = try f.engine.loadPackage("gone:content",
        \\@schema mymod:blob { source string }
        \\mymod:blob gone:blob { source "nowhere.bin" }
    );
    try f.engine.writeSource(gone, "present.bin", "x");
    try testing.expectEqual(Result.not_found, table.asset_acquire(core.ContentId.fromString("gone:blob"), &handle));

    // A record type nothing is registered to load, which for a mod usually means the
    // subsystem it wanted is not in this game.
    const unloadable = try f.engine.loadPackage("unloadable:content",
        \\@schema thing { source string }
        \\thing unloadable:thing { source "one.bin" }
    );
    try f.engine.writeSource(unloadable, "one.bin", "aaaa");
    try testing.expectEqual(
        Result.unavailable,
        table.asset_acquire(core.ContentId.fromString("unloadable:thing"), &handle),
    );
}

test "an asset handle nobody issued resolves to nothing" {
    const f = try Fixture.init();
    defer f.deinit();

    var refs: u32 = 0;
    var id: ContentId = .none;
    try testing.expectEqual(Result.invalid_handle, table.asset_refcount(.none, &refs));
    try testing.expectEqual(Result.invalid_handle, table.asset_content_id(.{ .bits = 5 }, &id));
    // Released rather than silently ignored: the difference between a mod being told it has
    // a bug and a mod leaking every asset it ever acquired.
    try testing.expectEqual(Result.invalid_handle, table.asset_release(.{ .bits = std.math.maxInt(u64) }));
}
