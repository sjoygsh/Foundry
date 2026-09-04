//! The asset registry: a content ID in, a loaded payload out.
//!
//! **The only way to reach a loaded asset** (`assets.md` §4). Nothing else opens a file on
//! content's behalf, and nothing is addressable by anything but its `ContentId` (ADR-0021).
//!
//! ## What a path is allowed to be here
//!
//! ADR-0021's structural promise is that *nothing can be looked up by path* — and that is
//! kept exactly. `acquire` takes a `ContentId` and there is no other entry point.
//!
//! A record found that way may then say where its bytes live, in its `source` field, and
//! this module reads them. That is location, not identity: `source` is an ordinary field a
//! mod can change in one line without any reference, save or other package noticing, and no
//! caller can turn a path back into an asset. Confusing the two would be the mistake the
//! ADR exists to prevent; refusing to read a file at all would leave the design's own
//! `SourceMissing` (§7) undefinable.
//!
//! ## Ownership
//!
//! Payloads belong to the loader that made them, and are freed by it. The registry holds a
//! payload as one opaque word and never looks inside — which is what lets `render2d` (L3)
//! own GPU textures while this module (L2) knows nothing about a GPU.
//!
//! **Deinit order matters and is not enforceable from here:** the registry must be torn
//! down *before* whatever registered the loaders, because its `deinit` calls them.
//!
//! Everything here reads files named by content, which means content from mods, which means
//! **untrusted input**: validated and refused, never asserted.
//!
//! Design: `docs/design/assets.md` §4, §5 and §7.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");

const schemas = @import("schemas.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const PackageHandle = data.store.PackageHandle;
const Record = data.store.Record;
const SchemaId = data.SchemaId;
const log = core.log.scoped(.asset);

/// Phantom tag for `AssetHandle` (I1).
pub const Assets = opaque {};
pub const AssetHandle = core.Handle(Assets);

/// What a loader produces, held opaquely.
///
/// **One 64-bit word, not a `*anyopaque`.** A loader's product is as often a handle as a
/// pointer — `render2d` returns a `TextureHandle`, which is a value — and a pointer-shaped
/// payload would force every such loader to heap-allocate a box for two `u32`s. A word
/// holds either. It is also the shape the public ABI wants (ADR-0004), where a handle is
/// already published as an opaque 64-bit value.
pub const Payload = extern struct {
    bits: u64 = 0,

    pub fn fromPointer(p: *anyopaque) Payload {
        return .{ .bits = @intFromPtr(p) };
    }

    pub fn pointer(self: Payload) ?*anyopaque {
        if (self.bits == 0) return null;
        return @ptrFromInt(@as(usize, @truncate(self.bits)));
    }

    pub fn fromHandle(handle: anytype) Payload {
        return .{ .bits = handle.bits() };
    }

    pub fn asHandle(self: Payload, comptime H: type) H {
        return H.fromBits(self.bits);
    }
};

/// Why a load failed, from the loader's side.
///
/// `assets.md` §7's table plus `LoadFailed`, which it did not have and needs: a loader can
/// fail for a reason that is neither the bytes' fault nor a version — the device refused
/// the texture, the file could not be read. Calling that `InvalidAsset` would send a mod
/// author to inspect a file that is perfectly fine.
pub const LoadError = error{
    /// The bytes are not what they claim to be. A decode failure.
    InvalidAsset,
    /// The asset's format is newer than this build understands (I8).
    UnsupportedVersion,
    /// Everything else that is not the content's fault.
    LoadFailed,
} || Allocator.Error;

pub const AcquireError = error{
    /// No record with that content ID in the merged store.
    AssetNotFound,
    /// The record exists but is not an asset kind, or not the kind asked for.
    WrongSchema,
    /// Nothing is registered for that schema — usually a subsystem not yet initialised.
    NoLoader,
    /// The record exists; its `source` file does not. Different failure, different fix.
    SourceMissing,
    /// The `source` field is not a path a package is allowed to name. §7's table did not
    /// have this one, and it is the security-relevant half of `SourceMissing`: a package
    /// that tries to read outside itself is refused loudly rather than merged into "not
    /// found", where nobody would ever look at it.
    SourceRejected,
} || LoadError;

pub const RegisterError = error{
    /// A loader is already registered for that schema. Adding is not replacing, and
    /// nothing yet has a reason to replace one — so the ambiguous case is refused rather
    /// than resolved by arrival order.
    LoaderExists,
} || Allocator.Error;

/// Turns a record plus its source bytes into a payload.
///
/// A plain struct of function pointers, which is what I6 asks for: the engine's own loaders
/// go in through this call and so would a mod's, and the registry cannot tell them apart.
/// It is deliberately C-ABI-shaped ahead of M7 — `ctx` rather than a closure, one word out
/// rather than a Zig type.
pub const Loader = struct {
    /// The record type this loader claims.
    schema: SchemaId,
    ctx: ?*anyopaque = null,
    load: *const fn (ctx: ?*anyopaque, gpa: Allocator, record: Record, bytes: []const u8) LoadError!Payload,
    unload: *const fn (ctx: ?*anyopaque, gpa: Allocator, payload: Payload) void,
};

/// A loaded asset, as a caller sees it.
pub const Asset = struct {
    id: ContentId,
    schema_id: SchemaId,
    payload: Payload,
};

pub const Options = struct {
    /// Refused before the file is read, not after. The decoders apply their own bounds to
    /// what a header claims; this one bounds what reaches them.
    max_source_bytes: usize = 64 << 20,
};

pub const Registry = struct {
    /// Holds the mounted roots. Nothing else: payloads belong to their loaders and record
    /// bytes belong to the store.
    arena: core.Arena,
    os: *platform.os.Os,
    store: *const data.Store,
    options: Options,

    /// Linear, because there are a handful of asset kinds and a lookup happens once per
    /// load rather than once per frame. Append-only, so an index into it is stable.
    loaders: std.ArrayList(Loader) = .empty,
    roots: std.AutoHashMapUnmanaged(PackageHandle, []const u8) = .empty,

    entries: core.HandlePool(Assets, Entry) = .empty,
    by_id: std.AutoHashMapUnmanaged(u64, AssetHandle) = .empty,

    const Entry = struct {
        id: ContentId,
        schema_id: SchemaId,
        /// Index into `loaders`. The loader that made a payload is the one that frees it,
        /// even if another is registered for that schema later.
        loader: u32,
        payload: Payload,
        /// Zero means evictable, not freed (§4).
        refs: u32,
    };

    pub fn init(gpa: Allocator, os: *platform.os.Os, store: *const data.Store, options: Options) Registry {
        return .{ .arena = .init(gpa), .os = os, .store = store, .options = options };
    }

    /// Unloads everything, whatever its reference count.
    ///
    /// A live count at shutdown is a leak on the caller's side, not a reason to keep GPU
    /// memory alive past the device that owns it.
    pub fn deinit(self: *Registry, gpa: Allocator) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const loader = self.loaders.items[entry.value.loader];
            loader.unload(loader.ctx, gpa, entry.value.payload);
        }
        self.entries.deinit(gpa);
        self.by_id.deinit(gpa);
        self.loaders.deinit(gpa);
        self.roots.deinit(gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    // -- registration ------------------------------------------------------------------

    /// Registers a loader for one record type (I6).
    pub fn registerLoader(self: *Registry, gpa: Allocator, loader: Loader) RegisterError!void {
        if (self.loaderIndex(loader.schema) != null) return error.LoaderExists;
        try self.loaders.append(gpa, loader);
    }

    pub fn loaderCount(self: *const Registry) u32 {
        return @intCast(self.loaders.items.len);
    }

    /// Says where a loaded package's files live, so `source` can be resolved against it.
    ///
    /// **Separate from loading the package, and deliberately so.** `data` consumes a merged
    /// store and does not assemble one (`assets.md` §10); a root is what *this* module needs
    /// to do its one job, so it is recorded here rather than pushed down into a `data` type
    /// that documents its own label as diagnostics-only.
    ///
    /// Mounting a package again replaces its root, which is what recompiling one during hot
    /// reload will need.
    pub fn mount(self: *Registry, gpa: Allocator, package: PackageHandle, root: []const u8) Allocator.Error!void {
        const owned = try self.arena.allocator().dupe(u8, root);
        try self.roots.put(gpa, package, owned);
    }

    pub fn rootOf(self: *const Registry, package: PackageHandle) ?[]const u8 {
        return self.roots.get(package);
    }

    // -- acquiring ---------------------------------------------------------------------

    /// Resolves and loads if needed; increments the reference count.
    pub fn acquire(self: *Registry, gpa: Allocator, id: ContentId) AcquireError!AssetHandle {
        return self.acquireInner(gpa, id, null);
    }

    /// The same, refusing anything that is not the record type asked for.
    ///
    /// For a caller that knows what it wants: drawing a sprite with something that turned
    /// out to be a sound is a mistake worth catching where the ID is written, not where the
    /// payload is cast.
    pub fn acquireOf(self: *Registry, gpa: Allocator, id: ContentId, schema_id: SchemaId) AcquireError!AssetHandle {
        return self.acquireInner(gpa, id, schema_id);
    }

    fn acquireInner(self: *Registry, gpa: Allocator, id: ContentId, expected: ?SchemaId) AcquireError!AssetHandle {
        const record = self.store.lookup(id) orelse {
            log.warn("asset {f} is not in any loaded package", .{id});
            return error.AssetNotFound;
        };
        if (expected) |want| {
            if (!record.schema_id.eql(want)) {
                log.warn("asset '{s}' is not the record type that was asked for", .{record.name});
                return error.WrongSchema;
            }
        }

        // Before the cache, so that asking for the wrong kind is refused whether or not
        // somebody else already loaded it.
        const loader_index = self.loaderIndex(record.schema_id) orelse {
            log.warn("no loader is registered for the record type of '{s}'", .{record.name});
            return error.NoLoader;
        };

        // A count that touched zero has not been freed (§4), so this is also the path that
        // brings one back: a texture shared by two levels is not unloaded between them.
        if (self.by_id.get(id.hash)) |existing| {
            const entry = self.entries.get(existing).?;
            entry.refs += 1;
            return existing;
        }

        const bytes = try self.readSource(gpa, record);
        defer gpa.free(bytes);

        const loader = self.loaders.items[loader_index];
        const payload = try loader.load(loader.ctx, gpa, record, bytes);
        errdefer loader.unload(loader.ctx, gpa, payload);

        // Reserved before the slot is taken, so a failure here cannot leave a loaded
        // payload the registry has lost track of.
        try self.by_id.ensureUnusedCapacity(gpa, 1);
        const handle = try self.entries.add(gpa, .{
            .id = id,
            .schema_id = record.schema_id,
            .loader = loader_index,
            .payload = payload,
            .refs = 1,
        });
        self.by_id.putAssumeCapacity(id.hash, handle);
        return handle;
    }

    /// Decrements. Reaching zero makes an asset evictable, not freed.
    pub fn release(self: *Registry, handle: AssetHandle) void {
        const entry = self.entries.get(handle) orelse {
            log.warn("release of an asset handle that is stale or was never issued", .{});
            return;
        };
        if (entry.refs == 0) {
            log.warn("asset {f} released more times than it was acquired", .{entry.id});
            return;
        }
        entry.refs -= 1;
    }

    pub fn get(self: *Registry, handle: AssetHandle) ?Asset {
        const entry = self.entries.get(handle) orelse return null;
        return .{ .id = entry.id, .schema_id = entry.schema_id, .payload = entry.payload };
    }

    pub fn payloadOf(self: *Registry, handle: AssetHandle) ?Payload {
        const entry = self.entries.get(handle) orelse return null;
        return entry.payload;
    }

    /// Diagnostics and tests. A caller reasoning about its own counts is a caller with a
    /// bug; this exists so the bug is visible.
    pub fn refCount(self: *Registry, handle: AssetHandle) ?u32 {
        const entry = self.entries.get(handle) orelse return null;
        return entry.refs;
    }

    /// The handle an ID is already loaded under, without loading it or counting a
    /// reference.
    pub fn find(self: *const Registry, id: ContentId) ?AssetHandle {
        return self.by_id.get(id.hash);
    }

    /// How many assets are loaded, evictable ones included.
    pub fn count(self: *const Registry) u32 {
        return self.entries.count();
    }

    /// Unloads every asset whose reference count is zero, and returns how many.
    ///
    /// **The mechanism, not the policy.** §9's first open question is *when* eviction runs,
    /// and answering it before there is a memory number to look at would be guessing. So
    /// nothing calls this on its own: a caller that knows it has just finished with a
    /// level's worth of content asks, and until one does, an unused asset stays resident —
    /// which is the behaviour §4 asked for.
    pub fn evictUnused(self: *Registry, gpa: Allocator) u32 {
        var freed: u32 = 0;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value.refs != 0) continue;
            const loader = self.loaders.items[entry.value.loader];
            loader.unload(loader.ctx, gpa, entry.value.payload);
            _ = self.by_id.remove(entry.value.id.hash);
            _ = self.entries.remove(entry.id);
            freed += 1;
        }
        return freed;
    }

    // -- internals ---------------------------------------------------------------------

    fn loaderIndex(self: *const Registry, schema_id: SchemaId) ?u32 {
        for (self.loaders.items, 0..) |loader, i| {
            if (loader.schema.eql(schema_id)) return @intCast(i);
        }
        return null;
    }

    /// The bytes a record's `source` names, read relative to its own package's root.
    ///
    /// Every step here is a refusal waiting to happen, because every input is a package's:
    /// the record must be shaped like an asset, the path must be one a package is allowed
    /// to name, the package must be mounted, and the file must be there and small enough.
    fn readSource(self: *Registry, gpa: Allocator, record: Record) AcquireError![]u8 {
        // Against the schema the record's own package carries, which is the one its bytes
        // are laid out by — not the registry's, which may have moved on.
        const index = record.schema.fieldIndex(schemas.source_field) orelse {
            log.warn("'{s}' is not an asset kind: its record type has no '{s}' field", .{
                record.name, schemas.source_field,
            });
            return error.WrongSchema;
        };
        const rel = record.fields.stringAt(index) catch |err| switch (err) {
            error.WrongType => {
                log.warn("'{s}' is not an asset kind: its '{s}' is not a string", .{
                    record.name, schemas.source_field,
                });
                return error.WrongSchema;
            },
            else => {
                log.warn("'{s}' cannot be read: its package's bytes are malformed", .{record.name});
                return error.InvalidAsset;
            },
        } orelse {
            log.warn("'{s}' has no '{s}' to read", .{ record.name, schemas.source_field });
            return error.WrongSchema;
        };

        if (!platform.os.isSafeRelativePath(rel)) {
            log.warn("'{s}' names a source outside its package: '{s}'", .{ record.name, rel });
            return error.SourceRejected;
        }

        const root = self.roots.get(record.package) orelse {
            log.warn("'{s}' comes from a package that was never mounted", .{record.name});
            return error.SourceMissing;
        };

        const path = platform.os.joinPath(gpa, &.{ root, rel }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.LoadFailed,
        };
        defer gpa.free(path);

        return self.os.readFile(gpa, path, self.options.max_source_bytes) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // The record is fine and the file is not there. This is the distinction §7
            // exists to keep: "your texture is missing" is a different sentence from
            // "your texture is corrupt", and a mod author needs to be told which.
            error.FileNotFound, error.WrongFileKind => {
                log.warn("'{s}' names '{s}', which is not there", .{ record.name, rel });
                return error.SourceMissing;
            },
            error.InvalidPath => error.SourceRejected,
            error.AccessDenied, error.FileTooLarge, error.IoFailed => {
                log.warn("'{s}': '{s}' could not be read ({s})", .{ record.name, rel, @errorName(err) });
                return error.LoadFailed;
            },
        };
    }
};

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;
const png = @import("png.zig");

/// A 1x1 RGBA PNG whose single pixel is (200, 40, 60, 255).
const one_pixel_png = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x38, 0xA1, 0x61, 0xF3,
    0x1F, 0x00, 0x05, 0x14, 0x02, 0x2C, 0xC2, 0x0E, 0x5D, 0x14, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

/// A stand-in for `render2d`'s texture loader: it decodes the same bytes and keeps the
/// result in ordinary memory, so this module's tests need no GPU and no L3 module.
const FakeTexture = struct {
    width: u32,
    height: u32,
    filter: []const u8,
    wrap: []const u8,
};

const FakeLoader = struct {
    loads: u32 = 0,
    unloads: u32 = 0,
    /// Set to make the next load fail, so the registry's error paths are reachable
    /// without a corrupt file for every one of them.
    fail: ?LoadError = null,

    fn loader(self: *FakeLoader, schema: SchemaId) Loader {
        return .{ .schema = schema, .ctx = self, .load = load, .unload = unload };
    }

    fn load(ctx: ?*anyopaque, gpa: Allocator, record: Record, bytes: []const u8) LoadError!Payload {
        const self: *FakeLoader = @ptrCast(@alignCast(ctx.?));
        if (self.fail) |err| return err;

        var image = png.decode(gpa, bytes, .{}) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnsupportedImage => error.UnsupportedVersion,
            else => error.InvalidAsset,
        };
        defer image.deinit(gpa);

        const made = try gpa.create(FakeTexture);
        made.* = .{
            .width = image.width,
            .height = image.height,
            // Read against the newest schema this build knows, which is what a real
            // loader has: its own constants.
            .filter = schemas.stringField(record, schemas.texture, schemas.filter_field) orelse "?",
            .wrap = schemas.stringField(record, schemas.texture, schemas.wrap_field) orelse "?",
        };
        self.loads += 1;
        return .fromPointer(made);
    }

    fn unload(ctx: ?*anyopaque, gpa: Allocator, payload: Payload) void {
        const self: *FakeLoader = @ptrCast(@alignCast(ctx.?));
        const made: *FakeTexture = @ptrCast(@alignCast(payload.pointer().?));
        gpa.destroy(made);
        self.unloads += 1;
    }
};

const check = @import("data").check;
const parser = @import("data").parser;

/// A package directory on disk, a compiled `.fpk` over it, and a registry pointed at both.
const Fixture = struct {
    gpa: Allocator,
    os: *platform.os.Os,
    dir: []u8,
    schemas_registry: data.Registry,
    diags: data.Diagnostics,
    store: data.Store,
    registry: Registry,
    blobs: std.ArrayList(std.ArrayList(u8)) = .empty,
    texture_loader: FakeLoader = .{},

    fn init() !*Fixture {
        const gpa = testing.allocator;
        const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-asset-test", .env = &.{} });
        errdefer os.deinit();

        const temp = try os.tempDirAlloc(gpa);
        defer gpa.free(temp);
        // A directory of its own per fixture, so two tests running over the same temp
        // directory cannot see each other's files.
        var name_buf: [64]u8 = undefined;
        const unique = std.fmt.bufPrint(&name_buf, "foundry-assets-{d}", .{std.testing.random_seed}) catch unreachable;
        const dir = try platform.os.joinPath(gpa, &.{ temp, unique });
        errdefer gpa.free(dir);
        try os.createDirPath(dir);

        const self = try gpa.create(Fixture);
        self.* = .{
            .gpa = gpa,
            .os = os,
            .dir = dir,
            .schemas_registry = .init(gpa, .default),
            .diags = .init(gpa, .default),
            .store = .init(gpa, .default),
            .registry = undefined,
        };
        self.registry = .init(gpa, os, &self.store, .{});
        try schemas.registerAll(gpa, &self.schemas_registry);
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.registry.deinit(self.gpa);
        self.store.deinit(self.gpa);
        self.schemas_registry.deinit(self.gpa);
        self.diags.deinit(self.gpa);
        for (self.blobs.items) |*b| b.deinit(self.gpa);
        self.blobs.deinit(self.gpa);
        self.gpa.free(self.dir);
        self.os.deinit();
        self.gpa.destroy(self);
    }

    fn writeFile(self: *Fixture, rel: []const u8, bytes: []const u8) !void {
        const path = try platform.os.joinPath(self.gpa, &.{ self.dir, rel });
        defer self.gpa.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.os.createDirPath(parent);
        try self.os.writeFile(path, bytes);
    }

    /// Compiles source into a package and loads it, the way `fpack` and the engine will.
    fn addPackage(self: *Fixture, name: []const u8, source: []const u8) !PackageHandle {
        var doc = try parser.parse(self.gpa, "test.fdt", source, .{
            .namespace = name[0..std.mem.indexOfScalar(u8, name, ':').?],
        }, &self.diags);
        defer doc.deinit(self.gpa);

        var pkg = try check.Package.init(self.gpa, name, 1, .default);
        defer pkg.deinit(self.gpa);
        try pkg.addDocument(self.gpa, &doc, &self.schemas_registry, &self.diags);

        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(self.gpa);
        try data.fpk.write(self.gpa, &pkg, &self.schemas_registry, &bytes);
        try self.blobs.append(self.gpa, bytes);

        const handle = try self.store.add(
            self.gpa,
            name,
            self.blobs.items[self.blobs.items.len - 1].items,
            &self.schemas_registry,
            &self.diags,
        );
        try self.registry.mount(self.gpa, handle, self.dir);
        return handle;
    }

    fn registerTextureLoader(self: *Fixture) !void {
        try self.registry.registerLoader(
            self.gpa,
            self.texture_loader.loader(schemas.texture.id),
        );
    }

    fn payload(self: *Fixture, handle: AssetHandle) *FakeTexture {
        return @ptrCast(@alignCast(self.registry.payloadOf(handle).?.pointer().?));
    }
};

const sprites_id = core.ContentId.fromString("foundry:textures.sprites");

const one_texture =
    \\foundry:texture foundry:textures.sprites { source "textures/sprites.png" }
;

test "a content id becomes bytes, decoded by a loader that was registered at runtime" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    try fx.registerTextureLoader();

    const handle = try fx.registry.acquire(fx.gpa, sprites_id);
    defer fx.registry.release(handle);

    try testing.expectEqual(@as(u32, 1), fx.registry.count());
    try testing.expectEqual(@as(u32, 1), fx.texture_loader.loads);
    try testing.expectEqual(@as(u32, 1), fx.payload(handle).width);

    const asset = fx.registry.get(handle).?;
    try testing.expect(asset.id.eql(sprites_id));
    try testing.expect(asset.schema_id.eql(schemas.texture.id));
}

test "acquiring twice loads once, and the second release makes it evictable" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    try fx.registerTextureLoader();

    const first = try fx.registry.acquire(fx.gpa, sprites_id);
    const second = try fx.registry.acquire(fx.gpa, sprites_id);
    try testing.expect(first.eql(second));
    try testing.expectEqual(@as(u32, 1), fx.texture_loader.loads);
    try testing.expectEqual(@as(u32, 2), fx.registry.refCount(first).?);

    fx.registry.release(first);
    try testing.expectEqual(@as(u32, 1), fx.registry.refCount(first).?);
    try testing.expectEqual(@as(u32, 0), fx.registry.evictUnused(fx.gpa));

    fx.registry.release(second);
    try testing.expectEqual(@as(u32, 0), fx.registry.refCount(first).?);
    // Zero is evictable, not freed: still resident, still resolving.
    try testing.expectEqual(@as(u32, 0), fx.texture_loader.unloads);
    try testing.expect(fx.registry.get(first) != null);
}

test "a count that reaches zero is not a reload, and eviction is what frees it" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    try fx.registerTextureLoader();

    const first = try fx.registry.acquire(fx.gpa, sprites_id);
    fx.registry.release(first);

    // The case §4 names: a texture two levels both use, released between them. Coming
    // back must not cost a decode.
    const again = try fx.registry.acquire(fx.gpa, sprites_id);
    try testing.expect(again.eql(first));
    try testing.expectEqual(@as(u32, 1), fx.texture_loader.loads);
    fx.registry.release(again);

    try testing.expectEqual(@as(u32, 1), fx.registry.evictUnused(fx.gpa));
    try testing.expectEqual(@as(u32, 1), fx.texture_loader.unloads);
    try testing.expectEqual(@as(u32, 0), fx.registry.count());
    // The handle is stale, and says so rather than resolving to whatever took its slot.
    try testing.expect(fx.registry.get(first) == null);
    try testing.expect(fx.registry.find(sprites_id) == null);

    // And it can be loaded again afterwards, under a new handle.
    const fresh = try fx.registry.acquire(fx.gpa, sprites_id);
    defer fx.registry.release(fresh);
    try testing.expect(!fresh.eql(first));
    try testing.expectEqual(@as(u32, 2), fx.texture_loader.loads);
}

test "every way an acquire can fail is a value, and they stay distinguishable" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    try fx.writeFile("textures/broken.png", "this is not a png");
    _ = try fx.addPackage("foundry:core",
        \\@schema note { text string }
        \\foundry:texture foundry:textures.sprites { source "textures/sprites.png" }
        \\foundry:texture foundry:textures.broken  { source "textures/broken.png" }
        \\foundry:texture foundry:textures.absent  { source "textures/absent.png" }
        \\foundry:texture foundry:textures.escape  { source "../../secrets.png" }
        \\note foundry:note.hello { text "not an asset" }
    );

    // Nothing registered yet: a subsystem that has not started is its own answer.
    try testing.expectError(error.NoLoader, fx.registry.acquire(fx.gpa, sprites_id));
    try fx.registerTextureLoader();

    try testing.expectError(
        error.AssetNotFound,
        fx.registry.acquire(fx.gpa, core.ContentId.fromString("foundry:textures.nope")),
    );
    // A record that exists and is not an asset kind — no loader claims `note`.
    try testing.expectError(
        error.NoLoader,
        fx.registry.acquire(fx.gpa, core.ContentId.fromString("foundry:note.hello")),
    );
    // A record that exists, is an asset, and is not the kind that was asked for.
    try testing.expectError(error.WrongSchema, fx.registry.acquireOf(
        fx.gpa,
        sprites_id,
        data.SchemaId.fromStringUnchecked("foundry:sound"),
    ));
    try testing.expectError(
        error.SourceMissing,
        fx.registry.acquire(fx.gpa, core.ContentId.fromString("foundry:textures.absent")),
    );
    try testing.expectError(
        error.SourceRejected,
        fx.registry.acquire(fx.gpa, core.ContentId.fromString("foundry:textures.escape")),
    );
    // The file is there and is not a PNG: corrupt, which is not the same as missing.
    try testing.expectError(
        error.InvalidAsset,
        fx.registry.acquire(fx.gpa, core.ContentId.fromString("foundry:textures.broken")),
    );

    // Nothing that failed is resident, and nothing that failed was counted.
    try testing.expectEqual(@as(u32, 0), fx.registry.count());
    try testing.expectEqual(@as(u32, 0), fx.texture_loader.loads);
}

test "a package whose files were never mounted is a missing source, not a crash" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    const pkg = try fx.addPackage("foundry:core", one_texture);
    try fx.registerTextureLoader();

    _ = fx.registry.roots.remove(pkg);
    try testing.expectError(error.SourceMissing, fx.registry.acquire(fx.gpa, sprites_id));
}

test "a loader that fails leaves nothing behind, however it failed" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    try fx.registerTextureLoader();

    for ([_]LoadError{ error.LoadFailed, error.UnsupportedVersion, error.OutOfMemory }) |err| {
        fx.texture_loader.fail = err;
        try testing.expectError(err, fx.registry.acquire(fx.gpa, sprites_id));
        try testing.expectEqual(@as(u32, 0), fx.registry.count());
        try testing.expect(fx.registry.find(sprites_id) == null);
    }

    // And the failures were not sticky: the same ID loads once the reason is gone.
    fx.texture_loader.fail = null;
    const handle = try fx.registry.acquire(fx.gpa, sprites_id);
    defer fx.registry.release(handle);
    try testing.expectEqual(@as(u32, 1), fx.texture_loader.loads);
}

test "one loader per record type; adding is not replacing" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.registerTextureLoader();
    try testing.expectError(error.LoaderExists, fx.registry.registerLoader(
        fx.gpa,
        fx.texture_loader.loader(schemas.texture.id),
    ));
    try testing.expectEqual(@as(u32, 1), fx.registry.loaderCount());
}

test "a mod's texture overrides the base game's, and the loader is handed the winner" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    try fx.writeFile("mods/replacement.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    _ = try fx.addPackage("mod:pack",
        \\foundry:texture foundry:textures.sprites { source "mods/replacement.png"  filter "linear" }
    );
    try fx.registerTextureLoader();

    // The override says only the ID. It does not mirror the base game's directory
    // layout, which is the whole point of ADR-0021.
    const handle = try fx.registry.acquire(fx.gpa, sprites_id);
    defer fx.registry.release(handle);
    try testing.expectEqualStrings("linear", fx.payload(handle).filter);
}

test "content compiled against version 1 of a schema is read, and fills the rest from defaults" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);

    // A package built before `filter` and `wrap` existed: one field, version 1. This is
    // what a mod compiled against last month's engine actually is.
    const v1: data.Schema = .{
        .id = schemas.texture.id,
        .version = 1,
        .fields = &.{.{ .name = schemas.source_field, .type = .string }},
    };
    var old_registry: data.Registry = .init(fx.gpa, .default);
    defer old_registry.deinit(fx.gpa);
    _ = try old_registry.register(fx.gpa, v1);

    var doc = try parser.parse(fx.gpa, "old.fdt", one_texture, .{ .namespace = "foundry" }, &fx.diags);
    defer doc.deinit(fx.gpa);
    var pkg = try check.Package.init(fx.gpa, "foundry:core", 1, .default);
    defer pkg.deinit(fx.gpa);
    try pkg.addDocument(fx.gpa, &doc, &old_registry, &fx.diags);

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(fx.gpa);
    try data.fpk.write(fx.gpa, &pkg, &old_registry, &bytes);
    try fx.blobs.append(fx.gpa, bytes);

    const handle = try fx.store.add(
        fx.gpa,
        "old.fpk",
        fx.blobs.items[fx.blobs.items.len - 1].items,
        &fx.schemas_registry,
        &fx.diags,
    );
    try fx.registry.mount(fx.gpa, handle, fx.dir);
    try fx.registerTextureLoader();

    const asset_handle = try fx.registry.acquire(fx.gpa, sprites_id);
    defer fx.registry.release(asset_handle);

    // The record has one field; the loader wants three. The two it does not have come
    // from the newest schema's defaults (I8), and nothing had to be recompiled.
    try testing.expectEqualStrings("nearest", fx.payload(asset_handle).filter);
    try testing.expectEqualStrings("clamp", fx.payload(asset_handle).wrap);
}

test "deinit unloads what is still held, so a leak at shutdown is not a leak" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    try fx.registerTextureLoader();

    // Acquired and deliberately never released: the fixture's `deinit` is what has to
    // free it, and `testing.allocator` is what checks that it did.
    _ = try fx.registry.acquire(fx.gpa, sprites_id);
    try testing.expectEqual(@as(u32, 1), fx.registry.count());
}
