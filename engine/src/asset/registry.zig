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
//! down *before* whatever registered the loaders, because its `deinit` calls them. A loader's
//! owner that has to go first calls `unregisterLoader`, which hands everything it made back
//! to it while it is still there to receive it.
//!
//! ## Private loaders
//!
//! A registered loader is unique per schema, and `acquire` means "through that one". A
//! consumer that needs the same record made into a different payload — `render3d`'s own
//! texture with its own colour space and mips, beside `render2d`'s — passes its loader to
//! `acquireWith` instead (`meshes.md` §7.4). **An entry is keyed by (content ID, loader)**: a
//! private loader is never registered, competes with nothing, and is invisible to `acquire`,
//! `find` and the public ABI. Everything else — counts, `release`, reloads, eviction, the
//! listing — treats its entries exactly as a registered loader's. Its owner leaves with
//! `unloadWith`, which is `unregisterLoader`'s promise for a loader nobody registered.
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

/// What a loader's `decode` hands its `finish`: one opaque word, as a payload is, owned by
/// the loader's `discard` until something frees it.
pub const Decoded = extern struct {
    bits: u64 = 0,

    pub fn fromPointer(p: *anyopaque) Decoded {
        return .{ .bits = @intFromPtr(p) };
    }

    pub fn pointer(self: Decoded) ?*anyopaque {
        if (self.bits == 0) return null;
        return @ptrFromInt(@as(usize, @truncate(self.bits)));
    }
};

/// What a finish may spend, shared by every finish of one `pump` (`background.md` §6.4).
pub const Budget = core.tasks.Budget;

/// A loader's work, split where the device begins (ADR-0062).
///
/// **One optional struct rather than three optional fields**, correcting §6.1's sketch: "all
/// or none" is then the type's, and a partial set cannot be written down, so nothing has to
/// refuse one.
pub const Split = struct {
    /// Read-only for the loader's lifetime: a device's limits, never the device.
    decode_ctx: ?*const anyopaque = null,
    /// **Pure.** It reads `decode_ctx`, the record and the bytes, and nothing else, on any
    /// thread. `gpa` is thread-safe, and is the allocator the finish and the eventual unload
    /// are handed too, so a decoded buffer may become the payload.
    decode: *const fn (decode_ctx: ?*const anyopaque, gpa: Allocator, record: Record, bytes: []const u8) LoadError!Decoded,
    /// On the main thread: makes the payload out of a decoded value, charging `budget` with
    /// the bytes it uploads. **It borrows `decoded`**; what happens to it afterwards is
    /// `after_finish`'s.
    finish: *const fn (ctx: ?*anyopaque, gpa: Allocator, record: Record, decoded: Decoded, budget: *Budget) LoadError!Payload,
    /// Frees a decoded value: one nobody finished, one a finish failed on, and one a finish
    /// succeeded with unless the finish adopted it.
    discard: *const fn (gpa: Allocator, decoded: Decoded) void,
    after_finish: AfterFinish = .free,
};

/// What becomes of a decoded value once a finish has succeeded with it.
pub const AfterFinish = enum {
    /// `discard`, on the main thread, straight after: for a value small enough that a task
    /// would cost more than its free.
    free,
    /// `discard`, by a third node of the job, on the pool. Returning a decoded texture's
    /// whole chain to the system cost 5.3 ms on the main thread, four times its upload
    /// (M27 Step 9).
    free_on_pool,
    /// The finish keeps it: a parsed skeleton is its own payload (`adoptDecoded`), and a
    /// sound's samples become the mixer's.
    adopt,
};

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
    /// A per-kind bound applied before the source is read. The registry-wide option remains
    /// an upper ceiling; a small text kind need not inherit a texture-sized allowance.
    max_source_bytes: usize = std.math.maxInt(usize),
    /// The whole load, on the calling thread. **A split loader's `load` is its `decode`, then
    /// its `finish`, then its `discard`** (ADR-0062), and the registry composes them itself
    /// (`loadWhole`) rather than trust a second implementation to agree.
    load: *const fn (ctx: ?*anyopaque, gpa: Allocator, record: Record, bytes: []const u8) LoadError!Payload,
    unload: *const fn (ctx: ?*anyopaque, gpa: Allocator, payload: Payload) void,
    /// Present when this loader's CPU work can leave the main thread. Without it, a request
    /// still loads: the read happens in the background and `load` runs as the finish.
    split: ?Split = null,

    /// Loader identity is part of an asset payload's provenance. A schema match alone is
    /// insufficient: two renderers can register the same texture schema, and each loader's
    /// context owns the texture handles it creates. Function pointers are compared by their
    /// code addresses rather than with `==`, which Zig does not define for function values.
    pub fn eql(a: Loader, b: Loader) bool {
        if ((a.split == null) != (b.split == null)) return false;
        if (a.split) |sa| {
            const sb = b.split.?;
            if (sa.decode_ctx != sb.decode_ctx or
                @intFromPtr(sa.decode) != @intFromPtr(sb.decode) or
                @intFromPtr(sa.finish) != @intFromPtr(sb.finish) or
                @intFromPtr(sa.discard) != @intFromPtr(sb.discard) or sa.after_finish != sb.after_finish) return false;
        }
        return a.schema.eql(b.schema) and a.ctx == b.ctx and
            a.max_source_bytes == b.max_source_bytes and
            @intFromPtr(a.load) == @intFromPtr(b.load) and
            @intFromPtr(a.unload) == @intFromPtr(b.unload);
    }

    /// The synchronous load: `load`, or for a split loader its three parts in order on this
    /// thread, under an unlimited budget. The one place the two paths can differ is here.
    pub fn loadWhole(self: Loader, gpa: Allocator, record: Record, bytes: []const u8) LoadError!Payload {
        const split = self.split orelse return self.load(self.ctx, gpa, record, bytes);
        const decoded = try split.decode(split.decode_ctx, gpa, record, bytes);
        var budget: Budget = .unlimited;
        const payload = split.finish(self.ctx, gpa, record, decoded, &budget) catch |err| {
            split.discard(gpa, decoded);
            return err;
        };
        if (split.after_finish != .adopt) split.discard(gpa, decoded);
        return payload;
    }
};

/// The finish of a loader whose decoded value **is** its payload: a parsed skeleton, a grid of
/// tile ids. It runs nothing on the main thread and hands the value over, which is why a
/// decode allocates through the allocator its payload is unloaded with.
pub fn adoptDecoded(_: ?*anyopaque, _: Allocator, _: Record, decoded: Decoded, _: *Budget) LoadError!Payload {
    return .{ .bits = decoded.bits };
}

/// Where an entry's payload is (`background.md` §6.2).
pub const State = union(enum) {
    /// `get` answers.
    ready,
    /// Requested and not yet finished. `get` returns null.
    pending,
    /// The background load failed, with what a synchronous one would have said. `get`
    /// returns null; a later `acquire` tries again on the calling thread.
    failed: AcquireError,
};

/// What one `pump` may spend on the main thread. Only work that moved there is bounded; a
/// finish that would exceed `upload_bytes` still runs if it is the pump's first, so a single
/// large texture cannot wait forever.
pub const PumpBudget = struct {
    upload_bytes: u64 = 8 << 20,
    max_finishes: u32 = 16,
};

pub const PumpStats = struct {
    /// Loads that became ready.
    finished: u32 = 0,
    /// Background reloads swapped in.
    reloaded: u32 = 0,
    /// Loads and reloads that failed this pump.
    failed: u32 = 0,
    /// Still in flight afterwards.
    pending: u32 = 0,
    /// What the finishes charged.
    bytes: u64 = 0,
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
    /// load rather than once per frame. Append-only, and a withdrawn loader leaves a
    /// vacancy rather than closing the gap, so an index into it is stable forever — an
    /// entry remembers which loader made its payload, and the answer must not shift under
    /// it. Registered and private loaders share the list, so an entry names its maker the
    /// same way whichever it is.
    loaders: std.ArrayList(?LoaderSlot) = .empty,
    roots: std.AutoHashMapUnmanaged(PackageHandle, []const u8) = .empty,

    entries: core.HandlePool(Assets, Entry) = .empty,
    /// Entries a registered loader made, by content ID. What `find` and the ABI see.
    by_id: std.AutoHashMapUnmanaged(u64, AssetHandle) = .empty,
    /// Entries a private loader made, by (content ID, loader slot).
    by_private: std.AutoHashMapUnmanaged(PrivateKey, AssetHandle) = .empty,

    /// Where requested work runs (`useTasks`).
    tasks: core.Tasks = core.tasks.immediate,
    /// In flight, in the order they were requested, which is the order `pump` finishes them
    /// (I9: the same requests give the same order, whatever the executor did).
    jobs: std.ArrayList(*Job) = .empty,
    /// Set when a held entry lost its job to `quiesce`, so the next pump starts it again.
    restart: bool = false,

    const LoaderSlot = struct {
        loader: Loader,
        /// False for a loader only ever passed to `acquireWith`.
        registered: bool,
    };

    const PrivateKey = struct { id: u64, slot: u32 };

    const Entry = struct {
        id: ContentId,
        schema_id: SchemaId,
        /// Index into `loaders`. The loader that made a payload is the one that frees it,
        /// even if another is registered for that schema later.
        loader: u32,
        payload: Payload,
        /// Zero means evictable, not freed (§4).
        refs: u32,
        /// What the source file looked like when this was loaded, for `reloadChanged`.
        stamp: Stamp,
        state: State = .ready,
        /// The load or background reload in flight for this entry. Never two.
        job: ?*Job = null,
    };

    /// One requested load or background reload: a two-node graph, a read and decode in the
    /// background and a finish on the main thread (ADR-0061, ADR-0062).
    ///
    /// On the heap and never moved, because an executor holds a pointer into its graph. The
    /// background node writes only `read`, `bytes`, `decoded` and `stamp`; everything else
    /// is the main thread's.
    const Job = struct {
        registry: *Registry,
        /// Thread-safe: the background node decodes through it, and the finish and the
        /// payload's eventual unload use it too.
        gpa: Allocator,
        handle: AssetHandle,
        loader_index: u32,
        loader: Loader,
        /// Borrowed from the store, which does not change while a job exists (`quiesce`).
        record: Record,
        location: SourceLocation,
        max_bytes: usize,
        /// A reload keeps the entry's payload current until it finishes.
        reload: bool,
        /// A reload's entry was stamped when it started, so a watcher does not start it
        /// twice. A reload that is cancelled puts the old stamp back, so it is tried again.
        previous_stamp: Stamp,
        /// The entry's count reached zero while it was pending: remove it once idle.
        removing: bool = false,
        graph: core.tasks.Graph,

        // Written by the background node.
        failure: ?AcquireError = null,
        bytes: ?[]u8 = null,
        decoded: ?Decoded = null,
        stamp: Stamp = .{},
        /// What the finish left to be freed, moved here on the main thread and freed by the
        /// third node on the pool. Read by the main thread again only once the graph is idle.
        trash_bytes: ?[]u8 = null,
        trash_decoded: ?Decoded = null,
        /// The finish installed the payload and the pump has counted it.
        counted: bool = false,

        /// Frees whatever the background node made and nobody used.
        fn releaseOutput(self: *Job) void {
            if (self.bytes) |bytes| self.gpa.free(bytes);
            self.bytes = null;
            if (self.decoded) |decoded| self.loader.split.?.discard(self.gpa, decoded);
            self.decoded = null;
        }

        /// The background node: read, and decode if the loader can. Logs nothing, because
        /// it is not on the main thread; the failure is reported when the pump sees it.
        fn readAndDecode(context: *anyopaque, _: *Budget) core.tasks.Outcome {
            const self: *Job = @ptrCast(@alignCast(context));
            const read = self.registry.os.readFileConfined(self.gpa, self.location.root, self.location.relative, self.max_bytes) catch |err| {
                self.failure = readFailure(err);
                return .failed;
            };
            self.stamp = .{ .modified_ns = read.info.modified_ns, .size = read.info.size };
            const split = self.loader.split orelse {
                self.bytes = read.bytes;
                return .ok;
            };
            defer self.gpa.free(read.bytes);
            self.decoded = split.decode(split.decode_ctx, self.gpa, self.record, read.bytes) catch |err| {
                self.failure = err;
                return .failed;
            };
            return .ok;
        }

        fn discardOutput(context: *anyopaque) void {
            const self: *Job = @ptrCast(@alignCast(context));
            self.releaseOutput();
        }

        /// The main node, inside `pump`: make the payload and put it behind the handle.
        fn finishNode(context: *anyopaque, budget: *Budget) core.tasks.Outcome {
            const self: *Job = @ptrCast(@alignCast(context));
            const payload = self.makePayload(budget) catch |err| {
                self.failure = err;
                self.releaseOutput();
                return .failed;
            };
            self.registry.install(self, payload);
            if (!self.freesOnPool()) {
                self.releaseOutput();
                return .ok;
            }
            // The entry is ready and needs nothing more of this job: what is left is freed on
            // the pool by the next node, and the job retires once that has run.
            if (self.registry.entries.get(self.handle)) |entry| if (entry.job == self) {
                entry.job = null;
            };
            self.trash_bytes = self.bytes;
            self.trash_decoded = self.decoded;
            self.bytes = null;
            self.decoded = null;
            return .ok;
        }

        /// The third node, on the pool: frees what the finish was done with.
        fn freeNode(context: *anyopaque, _: *Budget) core.tasks.Outcome {
            const self: *Job = @ptrCast(@alignCast(context));
            self.freeTrash();
            return .ok;
        }

        fn freesOnPool(self: *const Job) bool {
            const split = self.loader.split orelse return false;
            return split.after_finish == .free_on_pool;
        }

        fn freeTrash(self: *Job) void {
            if (self.trash_bytes) |bytes| self.gpa.free(bytes);
            self.trash_bytes = null;
            if (self.trash_decoded) |decoded| self.loader.split.?.discard(self.gpa, decoded);
            self.trash_decoded = null;
        }

        fn makePayload(self: *Job, budget: *Budget) LoadError!Payload {
            if (self.loader.split) |split| {
                const payload = try split.finish(self.loader.ctx, self.gpa, self.record, self.decoded.?, budget);
                if (split.after_finish == .adopt) self.decoded = null; // The finish keeps it.
                return payload;
            }
            const bytes = self.bytes.?;
            // A loader nobody split is charged its source, the best measure there is of
            // what it is about to upload.
            budget.charge(bytes.len);
            return self.loader.load(self.loader.ctx, self.gpa, self.record, bytes);
        }
    };

    /// Enough of a file to answer "did this change?" and nothing more.
    ///
    /// Modification time **and** size, because a wall clock is not monotonic (a corrected
    /// clock, a restored backup) and a coarse one can miss two edits in the same second.
    /// Two fields agreeing is a much better answer than either alone, and hashing the
    /// contents would mean reading every watched file on every check.
    pub const Stamp = struct {
        modified_ns: i64 = 0,
        size: u64 = 0,

        pub fn eql(a: Stamp, b: Stamp) bool {
            return a.modified_ns == b.modified_ns and a.size == b.size;
        }
    };

    pub fn init(gpa: Allocator, os: *platform.os.Os, store: *const data.Store, options: Options) Registry {
        return .{ .arena = .init(gpa), .os = os, .store = store, .options = options };
    }

    /// Unloads everything, whatever its reference count.
    ///
    /// A live count at shutdown is a leak on the caller's side, not a reason to keep GPU
    /// memory alive past the device that owns it.
    ///
    /// **Quiesces first** (§6.5), so nothing in flight outlives the registry it writes into.
    /// That is why the background pool is stopped after the registry, never before.
    pub fn deinit(self: *Registry, gpa: Allocator) void {
        self.quiesce();
        self.jobs.deinit(gpa);
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value.state != .ready) continue;
            const loader = self.loaders.items[entry.value.loader].?.loader;
            loader.unload(loader.ctx, gpa, entry.value.payload);
        }
        self.entries.deinit(gpa);
        self.by_id.deinit(gpa);
        self.by_private.deinit(gpa);
        self.loaders.deinit(gpa);
        self.roots.deinit(gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Where `request`s run (ADR-0061). Until this is called, requests run on
    /// `core.tasks.immediate`. Nothing may be in flight.
    ///
    /// A request decodes through the allocator it is handed, the one its payload is made
    /// and unloaded with, **which must therefore be thread-safe** whenever `tasks` has
    /// threads (M27 Step 5's Resolution).
    pub fn useTasks(self: *Registry, tasks: core.Tasks) void {
        std.debug.assert(self.jobs.items.len == 0);
        self.tasks = tasks;
    }

    // -- registration ------------------------------------------------------------------

    /// Registers a loader for one record type (I6).
    pub fn registerLoader(self: *Registry, gpa: Allocator, loader: Loader) RegisterError!void {
        if (self.loaderIndex(loader.schema) != null) return error.LoaderExists;
        try self.loaders.append(gpa, .{ .loader = loader, .registered = true });
    }

    /// Whether a record type has a loader right now.
    pub fn hasLoader(self: *const Registry, schema_id: SchemaId) bool {
        return self.loaderIndex(schema_id) != null;
    }

    /// Withdraws a loader and unloads everything it made, whatever the reference counts.
    ///
    /// **The way a loader's owner leaves safely.** A payload belongs to whoever made it, so
    /// a renderer that is about to shut down cannot simply stop answering: anything it
    /// loaded has to go back to it *first*, while it still exists. Doing that here rather
    /// than leaving it to teardown order means the rule is a call a caller can make, not a
    /// comment a caller can miss.
    ///
    /// Returns how many assets were unloaded. Nothing if no such loader is registered.
    pub fn unregisterLoader(self: *Registry, gpa: Allocator, schema_id: SchemaId) u32 {
        const index = self.loaderIndex(schema_id) orelse return 0;
        return self.withdraw(gpa, index);
    }

    /// Unloads everything a private loader made, whatever the reference counts, and forgets
    /// the loader: `unregisterLoader` for a loader only ever passed to `acquireWith`.
    ///
    /// Matched by `Loader.eql`, so its owner passes the value it acquired with. Returns how
    /// many assets were unloaded; nothing if that loader has nothing here. A registered
    /// loader is not a private one, and this never touches what a registered loader made.
    pub fn unloadWith(self: *Registry, gpa: Allocator, loader: Loader) u32 {
        const index = self.privateIndex(loader) orelse return 0;
        return self.withdraw(gpa, index);
    }

    /// Hands every entry a loader slot made back to it, then vacates the slot.
    fn withdraw(self: *Registry, gpa: Allocator, index: u32) u32 {
        const loader = self.loaders.items[index].?.loader;
        // A decode may be running through this loader's functions, which are about to go.
        for (self.jobs.items) |job| {
            if (job.loader_index == index) {
                self.quiesce();
                break;
            }
        }

        var unloaded: u32 = 0;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value.loader != index) continue;
            if (entry.value.refs != 0) {
                log.warn("asset {f} is still held; unloading it with its loader", .{entry.value.id});
            }
            if (entry.value.state == .ready) loader.unload(loader.ctx, gpa, entry.value.payload);
            self.forget(entry.value.*);
            _ = self.entries.remove(entry.id);
            unloaded += 1;
        }

        self.loaders.items[index] = null;
        return unloaded;
    }

    /// How many loaders are registered. Withdrawn ones do not count.
    pub fn loaderCount(self: *const Registry) u32 {
        var live: u32 = 0;
        for (self.loaders.items) |slot| {
            const s = slot orelse continue;
            if (s.registered) live += 1;
        }
        return live;
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
            try self.complete(gpa, existing);
            self.entries.get(existing).?.refs += 1;
            return existing;
        }

        const loader = self.loaders.items[loader_index].?.loader;
        const location = try self.sourceLocation(record);
        const loaded = try self.loadNow(gpa, record, location, loader);
        const payload = loaded.payload;
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
            .stamp = loaded.stamp,
        });
        self.by_id.putAssumeCapacity(id.hash, handle);
        return handle;
    }

    /// Resolves and loads through `loader`, which is **not registered**, and increments the
    /// reference count (`meshes.md` §7.4).
    ///
    /// For a consumer that needs its own payload for a record another loader may be
    /// registered for. The entry is keyed by (content ID, loader): the same ID through the
    /// same loader twice loads once, and through a different loader loads again. `acquire`,
    /// `find` and the public ABI never see these entries. `release`, `reload`,
    /// `reloadChanged`, `reloadAll`, `evictUnused`, `getIfLoader` and the listing treat them
    /// as they treat any other, and `unloadWith` hands them all back.
    ///
    /// The record must be `loader.schema`'s (`WrongSchema` otherwise), and `loader`'s own
    /// source bound applies, as a registered loader's does.
    pub fn acquireWith(self: *Registry, gpa: Allocator, id: ContentId, loader: Loader) AcquireError!AssetHandle {
        const record = self.store.lookup(id) orelse {
            log.warn("asset {f} is not in any loaded package", .{id});
            return error.AssetNotFound;
        };
        if (!record.schema_id.eql(loader.schema)) {
            log.warn("asset '{s}' is not the record type its loader makes", .{record.name});
            return error.WrongSchema;
        }

        const existing_slot = self.privateIndex(loader);
        if (existing_slot) |slot| {
            if (self.by_private.get(.{ .id = id.hash, .slot = slot })) |existing| {
                try self.complete(gpa, existing);
                self.entries.get(existing).?.refs += 1;
                return existing;
            }
        }

        const location = try self.sourceLocation(record);
        const loaded = try self.loadNow(gpa, record, location, loader);
        const payload = loaded.payload;
        errdefer loader.unload(loader.ctx, gpa, payload);

        // Everything that can fail is reserved before anything is taken, so a failure here
        // leaves neither a lost payload nor an empty loader slot behind.
        const slot: u32 = existing_slot orelse @intCast(self.loaders.items.len);
        if (existing_slot == null) try self.loaders.ensureUnusedCapacity(gpa, 1);
        try self.by_private.ensureUnusedCapacity(gpa, 1);
        const handle = try self.entries.add(gpa, .{
            .id = id,
            .schema_id = record.schema_id,
            .loader = slot,
            .payload = payload,
            .refs = 1,
            .stamp = loaded.stamp,
        });
        if (existing_slot == null) self.loaders.appendAssumeCapacity(.{ .loader = loader, .registered = false });
        self.by_private.putAssumeCapacity(.{ .id = id.hash, .slot = slot }, handle);
        return handle;
    }

    // -- requesting --------------------------------------------------------------------

    /// `acquire`, without waiting (`background.md` §6.2): a counted handle at once, ready if
    /// the asset is already here and otherwise pending until a `pump` finishes it.
    ///
    /// Every refusal that needs no bytes is returned now, named as `acquire` names it: no
    /// record, the wrong type, no loader, a path a package may not name, an unmounted
    /// package. What the bytes decide — a missing file, a corrupt one — arrives as the
    /// entry's `.failed` state, with the error a synchronous load would have returned.
    pub fn request(self: *Registry, gpa: Allocator, id: ContentId) AcquireError!AssetHandle {
        return self.requestInner(gpa, id, null);
    }

    /// `request`, refusing anything that is not the record type asked for.
    pub fn requestOf(self: *Registry, gpa: Allocator, id: ContentId, schema_id: SchemaId) AcquireError!AssetHandle {
        return self.requestInner(gpa, id, schema_id);
    }

    fn requestInner(self: *Registry, gpa: Allocator, id: ContentId, expected: ?SchemaId) AcquireError!AssetHandle {
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
        const loader_index = self.loaderIndex(record.schema_id) orelse {
            log.warn("no loader is registered for the record type of '{s}'", .{record.name});
            return error.NoLoader;
        };
        // Whatever state it is in, a second request is a second count on the same entry.
        if (self.by_id.get(id.hash)) |existing| {
            self.entries.get(existing).?.refs += 1;
            return existing;
        }

        const location = try self.sourceLocation(record);
        try self.by_id.ensureUnusedCapacity(gpa, 1);
        const handle = try self.addPending(gpa, id, record, loader_index);
        errdefer _ = self.entries.remove(handle);
        try self.startJob(gpa, handle, loader_index, record, location, .{});
        self.by_id.putAssumeCapacity(id.hash, handle);
        return handle;
    }

    /// `acquireWith`, without waiting: `request` through a loader that is not registered.
    pub fn requestWith(self: *Registry, gpa: Allocator, id: ContentId, loader: Loader) AcquireError!AssetHandle {
        const record = self.store.lookup(id) orelse {
            log.warn("asset {f} is not in any loaded package", .{id});
            return error.AssetNotFound;
        };
        if (!record.schema_id.eql(loader.schema)) {
            log.warn("asset '{s}' is not the record type its loader makes", .{record.name});
            return error.WrongSchema;
        }
        const existing_slot = self.privateIndex(loader);
        if (existing_slot) |slot| {
            if (self.by_private.get(.{ .id = id.hash, .slot = slot })) |existing| {
                self.entries.get(existing).?.refs += 1;
                return existing;
            }
        }

        const location = try self.sourceLocation(record);
        const slot: u32 = existing_slot orelse @intCast(self.loaders.items.len);
        try self.loaders.ensureUnusedCapacity(gpa, 1);
        try self.by_private.ensureUnusedCapacity(gpa, 1);
        const handle = try self.addPending(gpa, id, record, slot);
        errdefer _ = self.entries.remove(handle);
        if (existing_slot == null) self.loaders.appendAssumeCapacity(.{ .loader = loader, .registered = false });
        errdefer if (existing_slot == null) {
            _ = self.loaders.pop();
        };
        try self.startJob(gpa, handle, slot, record, location, .{});
        self.by_private.putAssumeCapacity(.{ .id = id.hash, .slot = slot }, handle);
        return handle;
    }

    /// Runs what is due on the main thread, once a frame, before any step (ADR-0061,
    /// decision 4): finishes whose decodes are done, in request order, within `limits`;
    /// failures, recorded and said once; cancelled work, freed.
    pub fn pump(self: *Registry, gpa: Allocator, limits: PumpBudget) PumpStats {
        if (self.restart) self.restartHeld(gpa);
        var budget: Budget = .{ .bytes = limits.upload_bytes, .nodes = limits.max_finishes };
        var stats: PumpStats = .{};
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            const job = self.jobs.items[i];
            const status = job.graph.poll(&budget);
            // Counted when the payload is installed, which may be a pump before the job's
            // last node has freed what it was done with.
            if (!job.counted and job.graph.finished(1)) {
                job.counted = true;
                if (job.reload) stats.reloaded += 1 else stats.finished += 1;
            }
            switch (status) {
                .pending => {
                    i += 1;
                    continue;
                },
                .done => {},
                .failed => stats.failed += 1,
                .cancelled => {},
            }
            self.retire(job, status);
        }
        stats.pending = @intCast(self.jobs.items.len);
        stats.bytes = budget.spent_bytes;
        return stats;
    }

    /// Cancels everything in flight and returns once nothing is (§6.3). What finished is
    /// discarded. An entry still held stays pending and starts again at the next `pump`, so
    /// the store may change in between — which is what this is for: `reloadContent` calls it
    /// before it replaces the packages records are borrowed from.
    pub fn quiesce(self: *Registry) void {
        if (self.jobs.items.len == 0) return;
        for (self.jobs.items) |job| job.graph.cancel();
        self.tasks.wait();
        while (self.jobs.items.len > 0) {
            const job = self.jobs.items[0];
            var budget: Budget = .unlimited;
            const status = job.graph.poll(&budget);
            std.debug.assert(status == .cancelled);
            self.retire(job, status);
        }
    }

    /// Whether anything is in flight.
    pub fn busy(self: *const Registry) bool {
        return self.jobs.items.len != 0;
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
        if (entry.refs != 0 or entry.state != .pending) return;

        // Nobody wants what is still loading (§6.5). It leaves the lookups now, so a new
        // request starts afresh, and the entry itself goes once its job is idle.
        self.forget(entry.*);
        if (entry.job) |job| {
            job.graph.cancel();
            job.removing = true;
        } else _ = self.entries.remove(handle);
    }

    pub fn get(self: *Registry, handle: AssetHandle) ?Asset {
        const entry = self.entries.get(handle) orelse return null;
        if (entry.state != .ready) return null;
        return .{ .id = entry.id, .schema_id = entry.schema_id, .payload = entry.payload };
    }

    /// Returns a loaded asset only when the loader that produced its current payload is
    /// exactly `expected`. The schema is checked as part of loader identity, while `ctx` and
    /// both callbacks prove that a payload belongs to the subsystem instance asking for it.
    /// This narrow query is intentionally the only way for a higher layer to validate opaque
    /// payload provenance without exposing the registry's loader table.
    pub fn getIfLoader(self: *Registry, handle: AssetHandle, expected: Loader) ?Asset {
        const entry = self.entries.get(handle) orelse return null;
        if (entry.state != .ready) return null;
        const actual = self.loaders.items[entry.loader] orelse return null;
        if (!actual.loader.eql(expected)) return null;
        return .{ .id = entry.id, .schema_id = entry.schema_id, .payload = entry.payload };
    }

    pub fn payloadOf(self: *Registry, handle: AssetHandle) ?Payload {
        const entry = self.entries.get(handle) orelse return null;
        if (entry.state != .ready) return null;
        return entry.payload;
    }

    /// The content ID behind a handle, in whatever state. Null for a stale handle.
    pub fn idOf(self: *Registry, handle: AssetHandle) ?ContentId {
        return (self.entries.get(handle) orelse return null).id;
    }

    /// Where a handle's asset is: ready, still loading, or failed and why. Null for a handle
    /// that is stale or was never issued.
    pub fn state(self: *Registry, handle: AssetHandle) ?State {
        const entry = self.entries.get(handle) orelse return null;
        return entry.state;
    }

    // -- reloading ---------------------------------------------------------------------

    /// Re-reads an asset's source and swaps the payload behind its handle.
    ///
    /// **The handle does not change, and neither does the reference count.** That is the
    /// whole mechanism `assets.md` §6 describes: everything holding the handle follows
    /// without being told, because the handle is what it holds (I1).
    ///
    /// **A failed reload changes nothing** (§6, rule 2). The new payload is built and only
    /// then is the old one released, so a texture someone is mid-edit — half-written, a
    /// syntax error away from valid — leaves the running program with the last thing that
    /// worked, and an error saying so.
    ///
    /// Callers who derived something from the payload (a `Region`, a size) have to derive
    /// it again: what a handle points at is what follows a swap, not what was copied out of
    /// it. `app` bumps a generation counter so a caller knows when.
    ///
    /// Synchronous, as it always was. Work in flight for the entry is cancelled first and
    /// this load replaces it; an entry that was pending or failed simply becomes ready.
    pub fn reload(self: *Registry, gpa: Allocator, handle: AssetHandle) AcquireError!void {
        const id, const previous = blk: {
            const entry = self.entries.get(handle) orelse {
                log.warn("reload of an asset handle that is stale or was never issued", .{});
                return error.AssetNotFound;
            };
            break :blk .{ entry.id, entry.loader };
        };

        // Looked up afresh: a package reload may have replaced the record with another
        // package's, changed where its bytes are, or changed its record type outright.
        const record = self.store.lookup(id) orelse {
            log.warn("asset {f} is no longer in any loaded package", .{id});
            return error.AssetNotFound;
        };
        const loader_index = try self.reloadLoader(previous, record);
        const loader = self.loaders.items[loader_index].?.loader;
        const location = try self.sourceLocation(record);
        const loaded = try self.loadNow(gpa, record, location, loader);

        // Past every failure. From here nothing can go wrong, which is what makes the swap
        // atomic from the caller's side.
        const entry = self.entries.get(handle).?;
        if (entry.job) |job| self.detach(job);
        if (entry.state == .ready) {
            const old = self.loaders.items[previous].?.loader;
            old.unload(old.ctx, gpa, entry.payload);
        }
        entry.payload = loaded.payload;
        entry.loader = loader_index;
        entry.schema_id = record.schema_id;
        entry.stamp = loaded.stamp;
        entry.state = .ready;
    }

    /// The loader a reload of an entry goes through. A registered entry follows its record
    /// to whichever loader now claims its type. A private one stays with the loader its
    /// owner chose, which makes one type only.
    fn reloadLoader(self: *Registry, previous: u32, record: Record) AcquireError!u32 {
        const previous_slot = self.loaders.items[previous].?;
        if (previous_slot.registered) return self.loaderIndex(record.schema_id) orelse {
            log.warn("no loader is registered for the record type of '{s}'", .{record.name});
            return error.NoLoader;
        };
        if (record.schema_id.eql(previous_slot.loader.schema)) return previous;
        log.warn("'{s}' is no longer the record type its loader makes", .{record.name});
        return error.WrongSchema;
    }

    /// Reloads every loaded asset whose source file has changed on disk.
    ///
    /// **Development only.** Nothing calls this in a shipped build, because nothing should
    /// be watching anything there (§6) — `app` decides, and defaults to build mode.
    ///
    /// Order is ascending slot index, which `core.HandlePool` documents and does not vary
    /// (I9): reloading many files gives the same result as reloading them one at a time.
    /// A failure is reported and skipped, leaving that asset as it was.
    ///
    /// **A ready entry whose loader is split reloads in the background** (§6.3): its old
    /// payload keeps drawing until a later `pump` swaps the new one in, and that is counted
    /// in `PumpStats.reloaded`, not here. An entry with work in flight is left to it.
    pub fn reloadChanged(self: *Registry, gpa: Allocator) u32 {
        var reloaded: u32 = 0;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value.job != null or entry.value.state == .pending) continue;
            const record = self.store.lookup(entry.value.id) orelse continue;
            const location = self.sourceLocation(record) catch continue;
            const now = self.stampOf(location);
            if (now.eql(entry.value.stamp)) continue;

            const handle = entry.id;
            if (entry.value.state == .ready) background: {
                const index = self.reloadLoader(entry.value.loader, record) catch break :background;
                if (self.loaders.items[index].?.loader.split == null) break :background;
                const previous = entry.value.stamp;
                entry.value.stamp = now;
                self.startJob(gpa, handle, index, record, location, .{ .reload = true, .previous_stamp = previous }) catch |err| {
                    entry.value.stamp = previous;
                    log.warn("'{s}' changed on disk but its reload could not start: {t}", .{ record.name, err });
                    continue;
                };
                continue;
            }
            self.reload(gpa, handle) catch |err| {
                log.warn("'{s}' changed on disk but did not reload: {t}", .{ record.name, err });
                // Stamped anyway, so a file that is broken *and* not being edited does not
                // produce the same complaint sixty times a second. The next real edit
                // changes the stamp again and it is retried.
                if (self.entries.get(handle)) |e| e.stamp = self.stampOf(location);
                continue;
            };
            log.info("reloaded '{s}'", .{record.name});
            reloaded += 1;
        }
        return reloaded;
    }

    /// Reloads every loaded asset, whatever its source looks like.
    ///
    /// For after a **package** reload, when the records themselves may have moved: a record
    /// can now name a different file, different sampler settings, or a different record
    /// type entirely, and none of that shows up as a changed source file. Reloading
    /// everything is the simple answer and this is a development path; comparing records to
    /// reload only what moved is an optimisation with a correctness risk and no measurement
    /// behind it yet.
    ///
    /// An asset whose record has gone from the store keeps what it has, with a warning —
    /// §6's rule 2 again, and better than handing its holders a hole.
    pub fn reloadAll(self: *Registry, gpa: Allocator) u32 {
        var reloaded: u32 = 0;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const id = entry.value.id;
            self.reload(gpa, entry.id) catch |err| {
                log.warn("asset {f} did not reload ({t}); keeping the last version", .{ id, err });
                continue;
            };
            reloaded += 1;
        }
        return reloaded;
    }

    /// Forgets every mounted root.
    ///
    /// For a package reload: the roots are keyed by handles into a store that is about to
    /// be replaced, and a handle from the old store means nothing to the new one. The
    /// caller re-mounts.
    pub fn clearMounts(self: *Registry) void {
        self.roots.clearRetainingCapacity();
        self.arena.reset();
    }

    /// Diagnostics and tests. A caller reasoning about its own counts is a caller with a
    /// bug; this exists so the bug is visible.
    pub fn refCount(self: *Registry, handle: AssetHandle) ?u32 {
        const entry = self.entries.get(handle) orelse return null;
        return entry.refs;
    }

    /// The handle an ID is already loaded under **by its registered loader**, without loading
    /// it or counting a reference. A private loader's entries are found by the handle
    /// `acquireWith` returned to their owner.
    pub fn find(self: *const Registry, id: ContentId) ?AssetHandle {
        return self.by_id.get(id.hash);
    }

    /// How many assets are loaded, evictable ones included.
    /// One loaded asset, as a reader sees it.
    ///
    /// A snapshot: `Payload` is an opaque word whose meaning belongs to the loader that
    /// made it, and handing one to a reader would be handing out something only its owner
    /// can interpret. What a browser wants is identity, kind and cost.
    pub const AssetInfo = struct {
        handle: AssetHandle,
        id: ContentId,
        schema_id: SchemaId,
        /// Zero means **evictable, not freed** (§4). The first time this is visible to
        /// anybody, and it is a real answer to "why is this still in memory".
        refs: u32,
        /// Ready, still loading, or failed (`background.md` §8).
        state: State,
    };

    /// Every loaded asset, **in handle-slot order**. An ID loaded through a registered loader
    /// and a private one appears once for each, because it is resident once for each.
    ///
    /// Stable for as long as nothing is loaded or evicted, which is what a stable order can
    /// mean for a pool whose contents come and go. A reader that wants a fixed order sorts
    /// its own copy (`debug-overlay.md` §3).
    pub fn assets(self: *const Registry) Iterator {
        return .{ .registry = self };
    }

    pub const Iterator = struct {
        registry: *const Registry,
        slot: u32 = 0,

        pub fn next(self: *Iterator) ?AssetInfo {
            while (self.registry.entries.slotAt(self.slot)) |at| {
                const index = self.slot;
                self.slot += 1;
                const entry = at.value orelse continue;
                return .{
                    .handle = .{ .index = index, .generation = at.generation },
                    .id = entry.id,
                    .schema_id = entry.schema_id,
                    .refs = entry.refs,
                    .state = entry.state,
                };
            }
            return null;
        }
    };

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
    ///
    /// An entry with work in flight is skipped (§6.5); a failed one has nothing to unload.
    pub fn evictUnused(self: *Registry, gpa: Allocator) u32 {
        var freed: u32 = 0;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value.refs != 0 or entry.value.job != null or entry.value.state == .pending) continue;
            const loader = self.loaders.items[entry.value.loader].?.loader;
            if (entry.value.state == .ready) loader.unload(loader.ctx, gpa, entry.value.payload);
            self.forget(entry.value.*);
            _ = self.entries.remove(entry.id);
            freed += 1;
        }
        return freed;
    }

    // -- internals ---------------------------------------------------------------------

    /// The registered loader for a schema. A private loader is never the answer.
    fn loaderIndex(self: *const Registry, schema_id: SchemaId) ?u32 {
        for (self.loaders.items, 0..) |slot, i| {
            const s = slot orelse continue;
            if (s.registered and s.loader.schema.eql(schema_id)) return @intCast(i);
        }
        return null;
    }

    /// The private loader equal to `loader`. A registered loader is never the answer.
    fn privateIndex(self: *const Registry, loader: Loader) ?u32 {
        for (self.loaders.items, 0..) |slot, i| {
            const s = slot orelse continue;
            if (!s.registered and s.loader.eql(loader)) return @intCast(i);
        }
        return null;
    }

    /// Drops an entry from whichever lookup holds it. The caller removes it from `entries`.
    fn forget(self: *Registry, entry: Entry) void {
        if (self.loaders.items[entry.loader].?.registered) {
            _ = self.by_id.remove(entry.id.hash);
        } else {
            _ = self.by_private.remove(.{ .id = entry.id.hash, .slot = entry.loader });
        }
    }

    fn addPending(self: *Registry, gpa: Allocator, id: ContentId, record: Record, loader_index: u32) Allocator.Error!AssetHandle {
        return self.entries.add(gpa, .{
            .id = id,
            .schema_id = record.schema_id,
            .loader = loader_index,
            .payload = .{},
            .refs = 1,
            .stamp = .{},
            .state = .pending,
        });
    }

    const JobOptions = struct { reload: bool = false, previous_stamp: Stamp = .{} };

    /// A job for `handle`, its two nodes and its place in the queue. Starts nothing: the
    /// decode starts at the next `pump`, and its finish runs at one after that.
    fn startJob(
        self: *Registry,
        gpa: Allocator,
        handle: AssetHandle,
        loader_index: u32,
        record: Record,
        location: SourceLocation,
        options: JobOptions,
    ) Allocator.Error!void {
        const loader = self.loaders.items[loader_index].?.loader;
        try self.jobs.ensureUnusedCapacity(gpa, 1);
        const job = try gpa.create(Job);
        errdefer gpa.destroy(job);
        job.* = .{
            .registry = self,
            .gpa = gpa,
            .handle = handle,
            .loader_index = loader_index,
            .loader = loader,
            .record = record,
            .location = location,
            .max_bytes = @min(self.options.max_source_bytes, loader.max_source_bytes),
            .reload = options.reload,
            .previous_stamp = options.previous_stamp,
            .graph = try core.tasks.Graph.init(gpa, self.tasks, .{ .nodes = 3, .edges = 2 }),
        };
        // At most three nodes into a graph made for three: no add can fail.
        _ = job.graph.add(.{ .kind = .background, .context = job, .call = Job.readAndDecode, .discard = Job.discardOutput }) catch unreachable;
        _ = job.graph.add(.{ .kind = .main, .context = job, .call = Job.finishNode, .after = &.{0} }) catch unreachable;
        if (job.freesOnPool()) _ = job.graph.add(.{ .kind = .background, .context = job, .call = Job.freeNode, .after = &.{1} }) catch unreachable;
        self.jobs.appendAssumeCapacity(job);
        self.entries.get(handle).?.job = job;
    }

    /// Puts a finished payload behind its handle. A reload hands the old one back to the
    /// loader that made it in the same breath, so nothing draws a freed texture.
    fn install(self: *Registry, job: *Job, payload: Payload) void {
        const entry = self.entries.get(job.handle).?;
        std.debug.assert(entry.job == job);
        if (job.reload and entry.state == .ready) {
            const old = self.loaders.items[entry.loader].?.loader;
            old.unload(old.ctx, job.gpa, entry.payload);
        }
        entry.payload = payload;
        entry.loader = job.loader_index;
        entry.schema_id = job.record.schema_id;
        entry.stamp = job.stamp;
        entry.state = .ready;
    }

    /// Takes a job that has nothing left running out of the queue, records what it came to
    /// on its entry, and frees it.
    fn retire(self: *Registry, job: *Job, status: core.tasks.Status) void {
        const index = std.mem.indexOfScalar(*Job, self.jobs.items, job).?;
        _ = self.jobs.orderedRemove(index);
        if (self.entries.get(job.handle)) |entry| if (entry.job == job) {
            entry.job = null;
            switch (status) {
                .done => {},
                .failed => {
                    const err = job.failure orelse error.LoadFailed;
                    // Said once, here, which is the only place a background failure is seen.
                    if (job.reload) {
                        log.warn("'{s}' changed on disk but did not reload: {t}", .{ job.record.name, err });
                    } else {
                        entry.state = .{ .failed = err };
                        log.warn("asset '{s}' did not load: {t}", .{ job.record.name, err });
                    }
                },
                .cancelled => if (job.removing) {
                    _ = self.entries.remove(job.handle);
                } else if (job.reload) {
                    entry.stamp = job.previous_stamp;
                } else {
                    self.restart = true;
                },
                .pending => unreachable,
            }
        };
        job.graph.deinit();
        job.releaseOutput();
        // Idle now, so this is safe on the main thread: a free node that never ran.
        job.freeTrash();
        job.gpa.destroy(job);
    }

    /// Cuts a job off from its entry, which something synchronous is about to settle. It is
    /// cancelled, and freed by a later pump once nothing of it is running.
    fn detach(self: *Registry, job: *Job) void {
        job.graph.cancel();
        if (self.entries.get(job.handle)) |entry| {
            if (entry.job == job) entry.job = null;
        }
    }

    /// Makes a pending or failed entry ready on the calling thread, for `acquire` (§6.2).
    /// A decode that already finished is finished here rather than repeated; one that has
    /// not is cancelled and done again now, so `acquire` never waits on the pool's queue.
    /// What `acquire` does to an entry it already has, without the count: a pending entry
    /// is finished on the calling thread, never by waiting on the pool, and a failed one is
    /// tried again there. A ready one is left as it is.
    pub fn complete(self: *Registry, gpa: Allocator, handle: AssetHandle) AcquireError!void {
        if (self.entries.get(handle) == null) return error.AssetNotFound;
        if (self.entries.get(handle).?.state == .ready) return;
        if (self.entries.get(handle).?.job) |job| {
            // Polled only if its decode has started: a poll would also start one that has
            // not, which this is about to do itself.
            const status: core.tasks.Status = if (job.graph.started(0)) settle: {
                var budget: Budget = .unlimited;
                break :settle job.graph.poll(&budget);
            } else .pending;
            switch (status) {
                .done, .failed => self.retire(job, status),
                .pending, .cancelled => self.detach(job),
            }
            if (self.entries.get(handle).?.state == .ready) return;
        }

        const entry = self.entries.get(handle).?;
        const record = self.store.lookup(entry.id) orelse {
            log.warn("asset {f} is no longer in any loaded package", .{entry.id});
            return error.AssetNotFound;
        };
        const loader = self.loaders.items[entry.loader].?.loader;
        const location = try self.sourceLocation(record);
        const loaded = self.loadNow(gpa, record, location, loader) catch |err| {
            self.entries.get(handle).?.state = .{ .failed = err };
            return err;
        };
        const settled = self.entries.get(handle).?;
        settled.payload = loaded.payload;
        settled.stamp = loaded.stamp;
        settled.state = .ready;
    }

    /// Starts again every held entry that `quiesce` left without its job, against the
    /// store as it is now. One that can no longer start is failed, as a request would be.
    fn restartHeld(self: *Registry, gpa: Allocator) void {
        self.restart = false;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value.state != .pending or entry.value.job != null) continue;
            const handle = entry.id;
            const err = restart: {
                const record = self.store.lookup(entry.value.id) orelse break :restart error.AssetNotFound;
                const index = self.reloadLoader(entry.value.loader, record) catch |e| break :restart e;
                const location = self.sourceLocation(record) catch |e| break :restart e;
                self.startJob(gpa, handle, index, record, location, .{}) catch |e| break :restart e;
                continue;
            };
            log.warn("asset {f} could not start loading again: {t}", .{ entry.value.id, err });
            entry.value.state = .{ .failed = err };
        }
    }

    const Loaded = struct { payload: Payload, stamp: Stamp };

    /// The synchronous load every path shares: read here, then `Loader.loadWhole`.
    fn loadNow(self: *Registry, gpa: Allocator, record: Record, location: SourceLocation, loader: Loader) AcquireError!Loaded {
        const read = try self.readSource(gpa, record, location, loader.max_source_bytes);
        defer gpa.free(read.bytes);
        const payload = try loader.loadWhole(gpa, record, read.bytes);
        return .{ .payload = payload, .stamp = .{ .modified_ns = read.info.modified_ns, .size = read.info.size } };
    }

    const SourceLocation = struct {
        root: []const u8,
        relative: []const u8,
    };

    /// Reads through the package root handle with symlink following disabled. The smaller
    /// of the host and loader bounds is applied before allocation/read.
    fn readSource(
        self: *Registry,
        gpa: Allocator,
        record: Record,
        location: SourceLocation,
        loader_max: usize,
    ) AcquireError!platform.os.FileRead {
        const max_bytes = @min(self.options.max_source_bytes, loader_max);
        return self.os.readFileConfined(gpa, location.root, location.relative, max_bytes) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // The record is fine and the file is not there. This is the distinction §7
            // exists to keep: "your texture is missing" is a different sentence from
            // "your texture is corrupt", and a mod author needs to be told which.
            error.FileNotFound, error.WrongFileKind => {
                log.warn("'{s}' names a source that is not there", .{record.name});
                return error.SourceMissing;
            },
            error.InvalidPath => error.SourceRejected,
            // `AlreadyExists` cannot arrive from a read; it is listed because the set is
            // exhaustive and an unlisted member would be a compile error the day one can.
            error.AlreadyExists, error.AccessDenied, error.FileTooLarge, error.IoFailed => {
                log.warn("'{s}': its source could not be read ({s})", .{ record.name, @errorName(err) });
                return error.LoadFailed;
            },
        };
    }

    /// `readSource`'s mapping, for a read off the main thread, which says nothing: the
    /// pump reports the failure where it is seen.
    fn readFailure(err: platform.os.FileError) AcquireError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.FileNotFound, error.WrongFileKind => error.SourceMissing,
            error.InvalidPath => error.SourceRejected,
            error.AlreadyExists, error.AccessDenied, error.FileTooLarge, error.IoFailed => error.LoadFailed,
        };
    }

    /// What a file looks like now, or a zero stamp if it cannot be seen at all.
    ///
    /// A file that has vanished stamps as zero, which differs from any real file — so it
    /// registers as a change and the reload attempt reports the missing source properly,
    /// rather than the watcher swallowing it.
    fn stampOf(self: *Registry, location: SourceLocation) Stamp {
        const info = self.os.statFileConfined(location.root, location.relative) catch return .{};
        return .{ .modified_ns = info.modified_ns, .size = info.size };
    }

    /// Where a record's `source` points, resolved against its own package's root.
    ///
    /// Every step here is a refusal waiting to happen, because every input is a package's:
    /// the record must be shaped like an asset, the path must be one a package is allowed
    /// to name, and the package must be mounted.
    fn sourceLocation(self: *Registry, record: Record) AcquireError!SourceLocation {
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

        return .{ .root = root, .relative = rel };
    }
};

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;
const png = @import("png.zig");
const image_mod = @import("image.zig");

/// A 1x1 RGBA PNG whose single pixel is (200, 40, 60, 255).
const one_pixel_png = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x38, 0xA1, 0x61, 0xF3,
    0x1F, 0x00, 0x05, 0x14, 0x02, 0x2C, 0xC2, 0x0E, 0x5D, 0x14, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

/// A 2x2 RGBA PNG. A different image at the same path, for the reload tests.
const four_pixel_png = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xB6, 0x0D, 0x24, 0x00, 0x00, 0x00,
    0x1B, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x38, 0xA1, 0x61, 0xF3,
    0x5F, 0xE4, 0x44, 0xC0, 0x7F, 0x06, 0x0D, 0x9B, 0x13, 0xFF, 0xFF, 0xFF,
    0x67, 0xF8, 0x0F, 0x00, 0x4D, 0xA1, 0x09, 0x7F, 0x63, 0xEE, 0x64, 0x39,
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
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
    tmp: std.testing.TmpDir,
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

        // A directory of its own per fixture, so no two tests can see each other's files.
        // `std`'s temporary directory, not `Os.tempDirAlloc`: this `Os` is handed no
        // environment, and on Windows only the environment names a temporary directory.
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_len = try tmp.dir.realPath(testing.io, &path_buf);
        const dir = try gpa.dupe(u8, path_buf[0..path_len]);
        errdefer gpa.free(dir);

        const self = try gpa.create(Fixture);
        self.* = .{
            .gpa = gpa,
            .os = os,
            .tmp = tmp,
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
        self.tmp.cleanup();
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

test "every loaded asset can be listed, with the reference count nobody could see before" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    try fx.registerTextureLoader();

    // Nothing loaded is an empty listing, not an absent one.
    var empty = fx.registry.assets();
    try testing.expect(empty.next() == null);

    const handle = try fx.registry.acquire(fx.gpa, sprites_id);
    _ = try fx.registry.acquire(fx.gpa, sprites_id);

    var it = fx.registry.assets();
    const info = it.next().?;
    try testing.expect(info.handle.eql(handle));
    try testing.expect(info.id.eql(sprites_id));
    try testing.expect(info.schema_id.eql(schemas.texture.id));
    try testing.expectEqual(@as(u32, 2), info.refs);
    try testing.expect(it.next() == null);

    // Zero references is **evictable, not freed** — and this is the first time that state
    // is visible to anybody, which is the answer to "why is this still in memory".
    fx.registry.release(handle);
    fx.registry.release(handle);
    var still = fx.registry.assets();
    try testing.expectEqual(@as(u32, 0), still.next().?.refs);

    // Eviction is what removes it from the listing.
    try testing.expectEqual(@as(u32, 1), fx.registry.evictUnused(fx.gpa));
    var gone = fx.registry.assets();
    try testing.expect(gone.next() == null);
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

test "a changed file reloads behind the handle, and the handle does not move" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    try fx.registerTextureLoader();

    const handle = try fx.registry.acquire(fx.gpa, sprites_id);
    defer fx.registry.release(handle);
    const before = fx.payload(handle);
    try testing.expectEqual(@as(u32, 1), before.width);

    // A different image at the same path: what an artist saving over a sprite does.
    try fx.writeFile("textures/sprites.png", &four_pixel_png);
    try fx.registry.reload(fx.gpa, handle);

    // Same handle, same reference count, new payload. Everything holding the handle
    // follows without being told, which is the whole of §6's mechanism.
    try testing.expectEqual(@as(u32, 1), fx.registry.refCount(handle).?);
    try testing.expectEqual(@as(u32, 2), fx.payload(handle).width);
    try testing.expectEqual(@as(u32, 2), fx.texture_loader.loads);
    try testing.expectEqual(@as(u32, 1), fx.texture_loader.unloads);
    try testing.expectEqual(@as(u32, 1), fx.registry.count());
}

test "loader provenance rejects another owner and follows reload through the handle" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    try fx.registerTextureLoader();

    const handle = try fx.registry.acquire(fx.gpa, sprites_id);
    defer fx.registry.release(handle);
    const expected = fx.texture_loader.loader(schemas.texture.id);
    const first = fx.registry.getIfLoader(handle, expected).?;
    const first_texture: *const FakeTexture = @ptrCast(@alignCast(first.payload.pointer().?));
    try testing.expectEqual(@as(u32, 1), first_texture.width);

    // The schema and handle bits are not provenance. A second subsystem instance uses the
    // same callbacks and schema but has a different owner context, and must not receive it.
    var other_owner: FakeLoader = .{};
    try testing.expect(fx.registry.getIfLoader(
        handle,
        other_owner.loader(schemas.texture.id),
    ) == null);

    try fx.writeFile("textures/sprites.png", &four_pixel_png);
    try fx.registry.reload(fx.gpa, handle);
    const reloaded = fx.registry.getIfLoader(handle, expected).?;
    const replacement: *const FakeTexture = @ptrCast(@alignCast(reloaded.payload.pointer().?));
    try testing.expectEqual(@as(u32, 2), replacement.width);
}

test "a reload that fails leaves the last thing that worked" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    try fx.registerTextureLoader();

    const handle = try fx.registry.acquire(fx.gpa, sprites_id);
    defer fx.registry.release(handle);

    // Half-saved, or being edited. §6 rule 2: the running program keeps what it has.
    try fx.writeFile("textures/sprites.png", "not a png any more");
    try testing.expectError(error.InvalidAsset, fx.registry.reload(fx.gpa, handle));
    try testing.expectEqual(@as(u32, 1), fx.payload(handle).width);
    try testing.expectEqual(@as(u32, 0), fx.texture_loader.unloads);

    // And the same for a source that has gone away entirely.
    fx.texture_loader.fail = error.LoadFailed;
    try testing.expectError(error.LoadFailed, fx.registry.reload(fx.gpa, handle));
    try testing.expectEqual(@as(u32, 1), fx.payload(handle).width);
    try testing.expectEqual(@as(u32, 0), fx.texture_loader.unloads);
}

test "only what changed reloads, and an unchanged file is not read twice" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    try fx.writeFile("textures/other.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core",
        \\foundry:texture foundry:textures.sprites { source "textures/sprites.png" }
        \\foundry:texture foundry:textures.other   { source "textures/other.png" }
    );
    try fx.registerTextureLoader();

    const sprites = try fx.registry.acquire(fx.gpa, sprites_id);
    defer fx.registry.release(sprites);
    const other = try fx.registry.acquire(fx.gpa, core.ContentId.fromString("foundry:textures.other"));
    defer fx.registry.release(other);
    try testing.expectEqual(@as(u32, 2), fx.texture_loader.loads);

    // Nothing has moved, so nothing is reloaded.
    try testing.expectEqual(@as(u32, 0), fx.registry.reloadChanged(fx.gpa));
    try testing.expectEqual(@as(u32, 2), fx.texture_loader.loads);

    try fx.writeFile("textures/sprites.png", &four_pixel_png);
    try testing.expectEqual(@as(u32, 1), fx.registry.reloadChanged(fx.gpa));
    try testing.expectEqual(@as(u32, 2), fx.payload(sprites).width);
    try testing.expectEqual(@as(u32, 1), fx.payload(other).width);

    // And the change is consumed: asking again finds nothing to do.
    try testing.expectEqual(@as(u32, 0), fx.registry.reloadChanged(fx.gpa));
}

test "a file that changed into rubbish is complained about once, not every frame" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    try fx.registerTextureLoader();

    const handle = try fx.registry.acquire(fx.gpa, sprites_id);
    defer fx.registry.release(handle);

    try fx.writeFile("textures/sprites.png", "still typing");
    try testing.expectEqual(@as(u32, 0), fx.registry.reloadChanged(fx.gpa));
    // Stamped despite failing, so a watcher polling twice a second does not produce the
    // same complaint twice a second.
    try testing.expectEqual(@as(u32, 0), fx.registry.reloadChanged(fx.gpa));
    try testing.expectEqual(@as(u32, 1), fx.payload(handle).width);

    // Fixing the file is a new change, and it is picked up.
    try fx.writeFile("textures/sprites.png", &four_pixel_png);
    try testing.expectEqual(@as(u32, 1), fx.registry.reloadChanged(fx.gpa));
    try testing.expectEqual(@as(u32, 2), fx.payload(handle).width);
}

test "a loader's owner can leave, taking everything it made with it" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    try fx.registerTextureLoader();

    // Deliberately still held. A renderer shutting down cannot wait for its callers to
    // tidy up, and unloading through a loader that has already gone is the crash this
    // call exists to make impossible.
    _ = try fx.registry.acquire(fx.gpa, sprites_id);

    try testing.expectEqual(@as(u32, 1), fx.registry.unregisterLoader(fx.gpa, schemas.texture.id));
    try testing.expectEqual(@as(u32, 1), fx.texture_loader.unloads);
    try testing.expectEqual(@as(u32, 0), fx.registry.count());
    try testing.expectEqual(@as(u32, 0), fx.registry.loaderCount());
    try testing.expect(!fx.registry.hasLoader(schemas.texture.id));

    // The record type is unclaimed again, so acquiring says exactly that.
    try testing.expectError(error.NoLoader, fx.registry.acquire(fx.gpa, sprites_id));

    // Withdrawing something that was never there is not an error.
    try testing.expectEqual(@as(u32, 0), fx.registry.unregisterLoader(fx.gpa, schemas.texture.id));

    // And the slot it left does not shift the indices of loaders registered after it: a
    // second loader goes in, loads, and unloads through itself.
    try fx.registerTextureLoader();
    const again = try fx.registry.acquire(fx.gpa, sprites_id);
    fx.registry.release(again);
    try testing.expectEqual(@as(u32, 1), fx.registry.evictUnused(fx.gpa));
    try testing.expectEqual(@as(u32, 2), fx.texture_loader.unloads);
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

// -- private loaders (`meshes.md` §7.4) --------------------------------------------------

test "a private loader makes its own payload beside the registered one's, and acquire cannot see it" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    try fx.registerTextureLoader();

    var mine: FakeLoader = .{};
    const private = mine.loader(schemas.texture.id);

    const shared = try fx.registry.acquire(fx.gpa, sprites_id);
    defer fx.registry.release(shared);
    const own = try fx.registry.acquireWith(fx.gpa, sprites_id, private);
    const again = try fx.registry.acquireWith(fx.gpa, sprites_id, private);

    // Keyed by (ID, loader): one load each, and the private entry counted twice.
    try testing.expect(!own.eql(shared));
    try testing.expect(own.eql(again));
    try testing.expectEqual(@as(u32, 1), fx.texture_loader.loads);
    try testing.expectEqual(@as(u32, 1), mine.loads);
    try testing.expectEqual(@as(u32, 2), fx.registry.refCount(own).?);
    try testing.expectEqual(@as(u32, 2), fx.registry.count());

    // What the registered loader means is untouched: `find` and `acquire` answer its entry,
    // and a private loader is not a registration.
    try testing.expect(fx.registry.find(sprites_id).?.eql(shared));
    try testing.expectEqual(@as(u32, 1), fx.registry.loaderCount());
    const third = try fx.registry.acquire(fx.gpa, sprites_id);
    try testing.expect(third.eql(shared));
    fx.registry.release(third);

    // Provenance tells the two payloads apart.
    try testing.expect(fx.registry.getIfLoader(own, private) != null);
    try testing.expect(fx.registry.getIfLoader(own, fx.texture_loader.loader(schemas.texture.id)) == null);
    try testing.expect(fx.registry.getIfLoader(shared, private) == null);

    // The listing shows the ID twice, because it is resident twice.
    var it = fx.registry.assets();
    var seen: u32 = 0;
    while (it.next()) |info| : (seen += 1) try testing.expect(info.id.eql(sprites_id));
    try testing.expectEqual(@as(u32, 2), seen);

    fx.registry.release(own);
    fx.registry.release(again);
}

test "a private loader needs no registration, and two private loaders do not share" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);

    var first: FakeLoader = .{};
    var second: FakeLoader = .{};
    const a = try fx.registry.acquireWith(fx.gpa, sprites_id, first.loader(schemas.texture.id));
    defer fx.registry.release(a);
    const b = try fx.registry.acquireWith(fx.gpa, sprites_id, second.loader(schemas.texture.id));
    defer fx.registry.release(b);

    try testing.expect(!a.eql(b));
    try testing.expectEqual(@as(u32, 1), first.loads);
    try testing.expectEqual(@as(u32, 1), second.loads);

    // Nothing is registered, so the shared path still says so.
    try testing.expectError(error.NoLoader, fx.registry.acquire(fx.gpa, sprites_id));
    try testing.expect(fx.registry.find(sprites_id) == null);
    try testing.expectEqual(@as(u32, 0), fx.registry.loaderCount());
    try testing.expect(!fx.registry.hasLoader(schemas.texture.id));
}

test "every way acquireWith can fail is a value, and leaves nothing behind" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    try fx.writeFile("textures/broken.png", "this is not a png");
    _ = try fx.addPackage("foundry:core",
        \\foundry:texture foundry:textures.sprites { source "textures/sprites.png" }
        \\foundry:texture foundry:textures.broken  { source "textures/broken.png" }
        \\foundry:texture foundry:textures.absent  { source "textures/absent.png" }
        \\foundry:texture foundry:textures.escape  { source "../../secrets.png" }
    );

    var mine: FakeLoader = .{};
    const private = mine.loader(schemas.texture.id);

    try testing.expectError(
        error.AssetNotFound,
        fx.registry.acquireWith(fx.gpa, core.ContentId.fromString("foundry:textures.nope"), private),
    );
    // A loader for another record type is refused before any file is read.
    var sounds: FakeLoader = .{};
    try testing.expectError(
        error.WrongSchema,
        fx.registry.acquireWith(fx.gpa, sprites_id, sounds.loader(schemas.sound.id)),
    );
    try testing.expectError(
        error.SourceMissing,
        fx.registry.acquireWith(fx.gpa, core.ContentId.fromString("foundry:textures.absent"), private),
    );
    try testing.expectError(
        error.SourceRejected,
        fx.registry.acquireWith(fx.gpa, core.ContentId.fromString("foundry:textures.escape"), private),
    );
    try testing.expectError(
        error.InvalidAsset,
        fx.registry.acquireWith(fx.gpa, core.ContentId.fromString("foundry:textures.broken"), private),
    );
    for ([_]LoadError{ error.LoadFailed, error.UnsupportedVersion, error.OutOfMemory }) |err| {
        mine.fail = err;
        try testing.expectError(err, fx.registry.acquireWith(fx.gpa, sprites_id, private));
    }
    // A loader's own source bound applies, as a registered loader's does.
    mine.fail = null;
    var small = private;
    small.max_source_bytes = 8;
    try testing.expectError(error.LoadFailed, fx.registry.acquireWith(fx.gpa, sprites_id, small));

    // Nothing resident, nothing loaded, and no failure took a loader slot.
    try testing.expectEqual(@as(u32, 0), fx.registry.count());
    try testing.expectEqual(@as(u32, 0), mine.loads);
    try testing.expectEqual(@as(usize, 0), fx.registry.loaders.items.len);

    // And the failures were not sticky.
    const handle = try fx.registry.acquireWith(fx.gpa, sprites_id, private);
    defer fx.registry.release(handle);
    try testing.expectEqual(@as(u32, 1), mine.loads);
}

test "a private loader's entries reload behind their handle, and a failed reload keeps the last" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    try fx.registerTextureLoader();

    var mine: FakeLoader = .{};
    const private = mine.loader(schemas.texture.id);
    const shared = try fx.registry.acquire(fx.gpa, sprites_id);
    defer fx.registry.release(shared);
    const own = try fx.registry.acquireWith(fx.gpa, sprites_id, private);
    defer fx.registry.release(own);

    // One changed file reloads both residents, each through its own loader.
    try fx.writeFile("textures/sprites.png", &four_pixel_png);
    try testing.expectEqual(@as(u32, 2), fx.registry.reloadChanged(fx.gpa));
    try testing.expectEqual(@as(u32, 2), fx.payload(own).width);
    try testing.expectEqual(@as(u32, 2), fx.payload(shared).width);
    try testing.expectEqual(@as(u32, 2), mine.loads);
    try testing.expectEqual(@as(u32, 1), mine.unloads);
    try testing.expectEqual(@as(u32, 2), fx.texture_loader.loads);
    try testing.expect(fx.registry.getIfLoader(own, private) != null);
    try testing.expectEqual(@as(u32, 1), fx.registry.refCount(own).?);

    // A failed reload changes nothing.
    mine.fail = error.LoadFailed;
    try testing.expectError(error.LoadFailed, fx.registry.reload(fx.gpa, own));
    try testing.expectEqual(@as(u32, 2), fx.payload(own).width);
    try testing.expectEqual(@as(u32, 1), mine.unloads);

    // `reloadAll` reaches it too, and counts only what it could do.
    try testing.expectEqual(@as(u32, 1), fx.registry.reloadAll(fx.gpa));
    mine.fail = null;
    try testing.expectEqual(@as(u32, 2), fx.registry.reloadAll(fx.gpa));
    try testing.expectEqual(@as(u32, 3), mine.loads);
}

test "a private entry whose record changed type is refused on reload, and kept" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);

    var mine: FakeLoader = .{};
    const own = try fx.registry.acquireWith(fx.gpa, sprites_id, mine.loader(schemas.texture.id));
    defer fx.registry.release(own);

    // A package reload replaces the store, and the same ID is now a sound. An override
    // cannot retype a record, but a rebuilt package can.
    fx.store.deinit(fx.gpa);
    fx.store = .init(fx.gpa, .default);
    fx.registry.clearMounts();
    _ = try fx.addPackage("foundry:core",
        \\foundry:sound foundry:textures.sprites { source "textures/sprites.png" }
    );

    try testing.expectError(error.WrongSchema, fx.registry.reload(fx.gpa, own));
    try testing.expectEqual(@as(u32, 1), fx.payload(own).width);
    try testing.expectEqual(@as(u32, 0), mine.unloads);
    try testing.expect(fx.registry.get(own).?.schema_id.eql(schemas.texture.id));
}

test "a private loader's unused entries evict, and come back under a new handle" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    try fx.registerTextureLoader();

    var mine: FakeLoader = .{};
    const private = mine.loader(schemas.texture.id);
    const shared = try fx.registry.acquire(fx.gpa, sprites_id);
    defer fx.registry.release(shared);
    const own = try fx.registry.acquireWith(fx.gpa, sprites_id, private);

    // Zero is evictable, not freed; coming back costs no load.
    fx.registry.release(own);
    try testing.expect((try fx.registry.acquireWith(fx.gpa, sprites_id, private)).eql(own));
    try testing.expectEqual(@as(u32, 1), mine.loads);
    fx.registry.release(own);

    // Eviction frees only the unheld private entry, through its own loader.
    try testing.expectEqual(@as(u32, 1), fx.registry.evictUnused(fx.gpa));
    try testing.expectEqual(@as(u32, 1), mine.unloads);
    try testing.expectEqual(@as(u32, 0), fx.texture_loader.unloads);
    try testing.expect(fx.registry.get(own) == null);
    try testing.expect(fx.registry.find(sprites_id).?.eql(shared));

    const fresh = try fx.registry.acquireWith(fx.gpa, sprites_id, private);
    defer fx.registry.release(fresh);
    try testing.expect(!fresh.eql(own));
    try testing.expectEqual(@as(u32, 2), mine.loads);
}

test "unloadWith hands back everything a private loader made, and nothing else" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    try fx.writeFile("textures/other.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core",
        \\foundry:texture foundry:textures.sprites { source "textures/sprites.png" }
        \\foundry:texture foundry:textures.other   { source "textures/other.png" }
    );
    try fx.registerTextureLoader();

    var mine: FakeLoader = .{};
    var theirs: FakeLoader = .{};
    const private = mine.loader(schemas.texture.id);
    const shared = try fx.registry.acquire(fx.gpa, sprites_id);
    defer fx.registry.release(shared);
    const kept = try fx.registry.acquireWith(fx.gpa, sprites_id, theirs.loader(schemas.texture.id));
    defer fx.registry.release(kept);

    // Deliberately still held, as a renderer's are when it shuts down.
    _ = try fx.registry.acquireWith(fx.gpa, sprites_id, private);
    _ = try fx.registry.acquireWith(fx.gpa, core.ContentId.fromString("foundry:textures.other"), private);

    try testing.expectEqual(@as(u32, 2), fx.registry.unloadWith(fx.gpa, private));
    try testing.expectEqual(@as(u32, 2), mine.unloads);
    try testing.expectEqual(@as(u32, 0), theirs.unloads);
    try testing.expectEqual(@as(u32, 0), fx.texture_loader.unloads);
    try testing.expectEqual(@as(u32, 2), fx.registry.count());
    try testing.expect(fx.registry.find(sprites_id).?.eql(shared));

    // Nothing left to hand back is not an error, and a registered loader is not a private one.
    try testing.expectEqual(@as(u32, 0), fx.registry.unloadWith(fx.gpa, private));
    try testing.expectEqual(@as(u32, 0), fx.registry.unloadWith(fx.gpa, fx.texture_loader.loader(schemas.texture.id)));
    try testing.expectEqual(@as(u32, 1), fx.registry.loaderCount());
    try testing.expect(fx.registry.get(shared) != null);

    // The loader can come back, and its entries load afresh.
    const again = try fx.registry.acquireWith(fx.gpa, sprites_id, private);
    defer fx.registry.release(again);
    try testing.expectEqual(@as(u32, 3), mine.loads);
}

test "deinit unloads what private loaders still hold" {
    const fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);

    // Never released and never handed back: `testing.allocator` checks that the fixture's
    // `deinit` freed it through its loader.
    var mine: FakeLoader = .{};
    _ = try fx.registry.acquireWith(fx.gpa, sprites_id, mine.loader(schemas.texture.id));
}

// -- M27 Step 4: requests, the pump and pending entries ---------------------------------

/// What `FakeSplit` makes: a decoded image's size and the sum of its bytes, so payloads made
/// by different paths can be compared for equality.
const FakeImage = struct {
    width: u32,
    height: u32,
    sum: u64,
    /// Copied out of the record, which belongs to a store that may be gone when compared.
    linear: bool,

    fn eql(a: FakeImage, b: FakeImage) bool {
        return a.width == b.width and a.height == b.height and a.sum == b.sum and a.linear == b.linear;
    }
};

/// A split loader over the same PNG decoder: decode on any thread, finish on this one.
const FakeSplit = struct {
    /// Counted on whatever thread decodes, so atomic. Everything else is the main thread's.
    decodes: std.atomic.Value(u32) = .init(0),
    finishes: u32 = 0,
    discards: u32 = 0,
    unloads: u32 = 0,
    /// Set to make the next finish fail.
    fail_finish: ?LoadError = null,

    fn loader(self: *FakeSplit, schema: SchemaId) Loader {
        return .{
            .schema = schema,
            .ctx = self,
            .load = load,
            .unload = unload,
            .split = .{ .decode_ctx = self, .decode = decode, .finish = finish, .discard = discard },
        };
    }

    /// ADR-0062: a split loader's `load` is its parts in order.
    fn load(ctx: ?*anyopaque, gpa: Allocator, record: Record, bytes: []const u8) LoadError!Payload {
        const self: *FakeSplit = @ptrCast(@alignCast(ctx.?));
        return self.loader(record.schema_id).loadWhole(gpa, record, bytes);
    }

    fn decode(ctx: ?*const anyopaque, gpa: Allocator, _: Record, bytes: []const u8) LoadError!Decoded {
        const self: *FakeSplit = @ptrCast(@alignCast(@constCast(ctx.?)));
        _ = self.decodes.fetchAdd(1, .monotonic);
        const image = try gpa.create(image_mod.Image);
        errdefer gpa.destroy(image);
        image.* = png.decode(gpa, bytes, .{}) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnsupportedImage => error.UnsupportedVersion,
            else => error.InvalidAsset,
        };
        return .fromPointer(image);
    }

    fn finish(ctx: ?*anyopaque, gpa: Allocator, record: Record, decoded: Decoded, budget: *Budget) LoadError!Payload {
        const self: *FakeSplit = @ptrCast(@alignCast(ctx.?));
        if (self.fail_finish) |err| return err;
        const image: *const image_mod.Image = @ptrCast(@alignCast(decoded.pointer().?));
        var sum: u64 = 0;
        for (image.pixels) |b| sum += b;
        budget.charge(image.pixels.len);
        const made = try gpa.create(FakeImage);
        made.* = .{
            .width = image.width,
            .height = image.height,
            .sum = sum,
            .linear = std.mem.eql(u8, schemas.stringField(record, schemas.texture, schemas.filter_field) orelse "", "linear"),
        };
        self.finishes += 1;
        return .fromPointer(made);
    }

    fn discard(gpa: Allocator, decoded: Decoded) void {
        const image: *image_mod.Image = @ptrCast(@alignCast(decoded.pointer().?));
        image.deinit(gpa);
        gpa.destroy(image);
    }

    fn unload(ctx: ?*anyopaque, gpa: Allocator, payload: Payload) void {
        const self: *FakeSplit = @ptrCast(@alignCast(ctx.?));
        gpa.destroy(@as(*FakeImage, @ptrCast(@alignCast(payload.pointer().?))));
        self.unloads += 1;
    }
};

fn imageOf(registry: *Registry, handle: AssetHandle) ?FakeImage {
    const payload = registry.payloadOf(handle) orelse return null;
    return @as(*const FakeImage, @ptrCast(@alignCast(payload.pointer().?))).*;
}

const three_textures =
    \\foundry:texture foundry:textures.a { source "textures/a.png" }
    \\foundry:texture foundry:textures.b { source "textures/b.png" filter "linear" }
    \\foundry:texture foundry:textures.c { source "textures/c.png" }
;
const texture_ids = [_]ContentId{
    .fromString("foundry:textures.a"),
    .fromString("foundry:textures.b"),
    .fromString("foundry:textures.c"),
};

fn writeThree(fx: *Fixture) !void {
    try fx.writeFile("textures/a.png", &one_pixel_png);
    try fx.writeFile("textures/b.png", &four_pixel_png);
    try fx.writeFile("textures/c.png", &four_pixel_png);
    _ = try fx.addPackage("foundry:core", three_textures);
}

/// What the synchronous path makes of each of the three, through a fresh registry.
fn syncImages() ![3]FakeImage {
    const fx = try Fixture.init();
    defer fx.deinit();
    try writeThree(fx);
    var split: FakeSplit = .{};
    try fx.registry.registerLoader(fx.gpa, split.loader(schemas.texture.id));
    var out: [3]FakeImage = undefined;
    for (texture_ids, &out) |id, *image| {
        const handle = try fx.registry.acquire(fx.gpa, id);
        image.* = imageOf(&fx.registry, handle).?;
    }
    // One decode, one finish and one discard each, all on this thread: `load` composed.
    try testing.expectEqual(@as(u32, 3), split.decodes.load(.monotonic));
    try testing.expectEqual(@as(u32, 3), split.finishes);
    return out;
}

const Order = enum { forward, reverse };

/// Requests all three under `Manual`, completes their decodes in `order` across several
/// pumps, and returns what they became.
fn manualImages(order: Order) ![3]FakeImage {
    const fx = try Fixture.init();
    defer fx.deinit();
    try writeThree(fx);
    var split: FakeSplit = .{};
    try fx.registry.registerLoader(fx.gpa, split.loader(schemas.texture.id));
    var manual = try core.tasks.Manual.init(testing.allocator, 8);
    defer manual.deinit();
    fx.registry.useTasks(manual.tasks());

    var handles: [3]AssetHandle = undefined;
    for (texture_ids, &handles) |id, *h| h.* = try fx.registry.request(fx.gpa, id);
    for (handles) |h| try testing.expectEqual(State.pending, fx.registry.state(h).?);

    // The first pump starts the three decodes; nothing has run, so nothing finishes.
    var stats = fx.registry.pump(fx.gpa, .{});
    try testing.expectEqual(@as(u32, 3), manual.pending());
    try testing.expectEqual(@as(u32, 0), stats.finished);
    // One decode completes per pump, held across the others, in the order asked for.
    var finished: u32 = 0;
    while (manual.pending() > 0) {
        switch (order) {
            .forward => manual.runNext(),
            .reverse => manual.runLast(),
        }
        stats = fx.registry.pump(fx.gpa, .{});
        try testing.expectEqual(@as(u32, 1), stats.finished);
        finished += stats.finished;
    }
    try testing.expectEqual(@as(u32, 3), finished);
    try testing.expectEqual(@as(u32, 0), stats.pending);
    try testing.expect(!fx.registry.busy());
    // Every decoded value was discarded once its finish had used it.
    var out: [3]FakeImage = undefined;
    for (handles, &out) |h, *image| {
        try testing.expectEqual(State.ready, fx.registry.state(h).?);
        image.* = imageOf(&fx.registry, h).?;
    }
    return out;
}

fn poolImages(threads: u16) ![3]FakeImage {
    const fx = try Fixture.init();
    defer fx.deinit();
    try writeThree(fx);
    var split: FakeSplit = .{};
    try fx.registry.registerLoader(fx.gpa, split.loader(schemas.texture.id));
    const pool = try fx.os.startBackground(testing.allocator, .{ .count = threads });
    // After the registry, as the engine orders them: the registry quiesces into the pool.
    defer pool.deinit();
    fx.registry.useTasks(pool.tasks());

    var handles: [3]AssetHandle = undefined;
    for (texture_ids, &handles) |id, *h| h.* = try fx.registry.request(fx.gpa, id);
    while (fx.registry.busy()) {
        _ = fx.registry.pump(fx.gpa, .{});
        pool.tasks().wait();
    }
    var out: [3]FakeImage = undefined;
    for (handles, &out) |h, *image| image.* = imageOf(&fx.registry, h).?;
    // The registry is freed here, before the pool, by the defers' order.
    fx.registry.quiesce();
    return out;
}

test "a request makes what acquire makes, under the inline executor, either order of completion and the pool" {
    const expected = try syncImages();
    try testing.expect(!expected[0].eql(expected[1])); // three different answers to compare
    for ([_]Order{ .forward, .reverse }) |order| {
        const got = try manualImages(order);
        for (expected, got) |e, g| try testing.expect(e.eql(g));
    }
    for ([_]u16{ 0, 1, 2 }) |threads| {
        const got = try poolImages(threads);
        for (expected, got) |e, g| try testing.expect(e.eql(g));
    }

    // Under `immediate` a request's decode and finish both happen in the first pump.
    const fx = try Fixture.init();
    defer fx.deinit();
    try writeThree(fx);
    var split: FakeSplit = .{};
    try fx.registry.registerLoader(fx.gpa, split.loader(schemas.texture.id));
    var handles: [3]AssetHandle = undefined;
    for (texture_ids, &handles) |id, *h| h.* = try fx.registry.request(fx.gpa, id);
    try testing.expectEqual(@as(u32, 0), split.decodes.load(.monotonic)); // nothing yet
    try testing.expect(fx.registry.get(handles[0]) == null);
    const stats = fx.registry.pump(fx.gpa, .{});
    try testing.expectEqual(@as(u32, 3), stats.finished);
    for (expected, handles) |e, h| try testing.expect(e.eql(imageOf(&fx.registry, h).?));
}

test "every refusal a request can make without the bytes is made at once, named, and leaves nothing" {
    const fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.addPackage("foundry:core",
        \\foundry:texture foundry:textures.escape { source "../outside.png" }
        \\foundry:texture foundry:textures.fine { source "textures/fine.png" }
        \\@schema thing { size u32 }
        \\thing foundry:things.one { size 3 }
    );
    var split: FakeSplit = .{};
    const private = split.loader(schemas.texture.id);

    // No loader is registered yet.
    try testing.expectError(error.NoLoader, fx.registry.request(fx.gpa, .fromString("foundry:textures.fine")));
    try fx.registry.registerLoader(fx.gpa, private);
    try testing.expectError(error.AssetNotFound, fx.registry.request(fx.gpa, .fromString("foundry:textures.none")));
    try testing.expectError(error.WrongSchema, fx.registry.requestOf(fx.gpa, .fromString("foundry:textures.fine"), schemas.mesh.id));
    try testing.expectError(error.SourceRejected, fx.registry.request(fx.gpa, .fromString("foundry:textures.escape")));
    try testing.expectError(error.WrongSchema, fx.registry.requestWith(fx.gpa, .fromString("foundry:things.one"), private));

    // An unmounted package: its files cannot be found, which is said before any read.
    fx.registry.clearMounts();
    try testing.expectError(error.SourceMissing, fx.registry.request(fx.gpa, .fromString("foundry:textures.fine")));

    try testing.expectEqual(@as(u32, 0), fx.registry.count());
    try testing.expect(!fx.registry.busy());
    try testing.expectEqual(@as(u32, 0), split.decodes.load(.monotonic));
}

test "what only the bytes can refuse fails in the background, is said once, and acquire tries again" {
    const fx = try Fixture.init();
    defer fx.deinit();
    try fx.writeFile("textures/b.png", "not a png");
    _ = try fx.addPackage("foundry:core", three_textures);
    var split: FakeSplit = .{};
    try fx.registry.registerLoader(fx.gpa, split.loader(schemas.texture.id));

    const missing = try fx.registry.request(fx.gpa, texture_ids[0]);
    defer fx.registry.release(missing);
    const corrupt = try fx.registry.request(fx.gpa, texture_ids[1]);
    defer fx.registry.release(corrupt);
    const once = fx.registry.pump(fx.gpa, .{});
    try testing.expectEqual(@as(u32, 2), once.failed);
    try testing.expectEqual(State{ .failed = error.SourceMissing }, fx.registry.state(missing).?);
    try testing.expectEqual(State{ .failed = error.InvalidAsset }, fx.registry.state(corrupt).?);
    try testing.expect(fx.registry.get(missing) == null);
    // Nothing is retried on its own, so nothing is said again.
    try testing.expectEqual(PumpStats{}, fx.registry.pump(fx.gpa, .{}));
    // A second request counts on the failed entry without loading it.
    const again = try fx.registry.request(fx.gpa, texture_ids[0]);
    fx.registry.release(again);
    try testing.expectEqual(@as(u32, 1), fx.registry.refCount(missing).?);

    // `acquire` keeps its meaning: a synchronous load, now, which succeeds once the file is there.
    try testing.expectError(error.SourceMissing, fx.registry.acquire(fx.gpa, texture_ids[0]));
    try testing.expectEqual(@as(u32, 1), fx.registry.refCount(missing).?);
    try fx.writeFile("textures/a.png", &one_pixel_png);
    const fixed = try fx.registry.acquire(fx.gpa, texture_ids[0]);
    defer fx.registry.release(fixed);
    try testing.expect(fixed.eql(missing));
    try testing.expectEqual(State.ready, fx.registry.state(missing).?);
    try testing.expectEqual(@as(u32, 1), imageOf(&fx.registry, missing).?.width);
}

test "acquire completes a pending entry, from its finished decode or by decoding again on the spot" {
    const fx = try Fixture.init();
    defer fx.deinit();
    try writeThree(fx);
    var split: FakeSplit = .{};
    try fx.registry.registerLoader(fx.gpa, split.loader(schemas.texture.id));
    var manual = try core.tasks.Manual.init(testing.allocator, 8);
    fx.registry.useTasks(manual.tasks());

    // Decoded already, not finished: acquire finishes it, and does not decode again.
    const a = try fx.registry.request(fx.gpa, texture_ids[0]);
    _ = fx.registry.pump(fx.gpa, .{});
    manual.runAll();
    try testing.expectEqual(State.pending, fx.registry.state(a).?);
    try testing.expect(a.eql(try fx.registry.acquire(fx.gpa, texture_ids[0])));
    try testing.expectEqual(State.ready, fx.registry.state(a).?);
    try testing.expectEqual(@as(u32, 1), split.decodes.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), fx.registry.refCount(a).?);
    try testing.expect(!fx.registry.busy());

    // Queued and not run: acquire does not wait on the queue, it decodes here.
    const b = try fx.registry.request(fx.gpa, texture_ids[1]);
    _ = fx.registry.pump(fx.gpa, .{});
    try testing.expectEqual(@as(u32, 1), manual.pending());
    try testing.expect(b.eql(try fx.registry.acquire(fx.gpa, texture_ids[1])));
    try testing.expectEqual(State.ready, fx.registry.state(b).?);
    try testing.expectEqual(@as(u32, 4), imageOf(&fx.registry, b).?.width * imageOf(&fx.registry, b).?.height);
    // The cancelled decode still runs, and the next pump throws its result away.
    manual.runAll();
    const after = fx.registry.pump(fx.gpa, .{});
    try testing.expectEqual(@as(u32, 0), after.finished);
    try testing.expectEqual(@as(u32, 2), split.finishes);
    try testing.expectEqual(@as(u32, 0), split.unloads);
    try testing.expect(!fx.registry.busy());

    // Never started: the same, with nothing in the queue.
    const c = try fx.registry.request(fx.gpa, texture_ids[2]);
    try testing.expect(c.eql(try fx.registry.acquire(fx.gpa, texture_ids[2])));
    _ = fx.registry.pump(fx.gpa, .{});
    try testing.expectEqual(@as(u32, 0), manual.pending());
    try testing.expect(!fx.registry.busy());
    manual.deinit();
}

test "complete finishes a pending entry without a count, and the listing says where each entry is" {
    const fx = try Fixture.init();
    defer fx.deinit();
    try writeThree(fx);
    var split: FakeSplit = .{};
    try fx.registry.registerLoader(fx.gpa, split.loader(schemas.texture.id));
    var manual = try core.tasks.Manual.init(testing.allocator, 8);
    defer manual.deinit();
    fx.registry.useTasks(manual.tasks());

    const a = try fx.registry.request(fx.gpa, texture_ids[0]);
    const b = try fx.registry.request(fx.gpa, texture_ids[1]);
    _ = fx.registry.pump(fx.gpa, .{});
    // The content ID answers in every state; a stale handle has none.
    try testing.expect(fx.registry.idOf(a).?.eql(texture_ids[0]));
    var it = fx.registry.assets();
    while (it.next()) |info| try testing.expectEqual(State.pending, info.state);

    try fx.registry.complete(fx.gpa, a);
    try testing.expectEqual(State.ready, fx.registry.state(a).?);
    try testing.expectEqual(@as(u32, 1), fx.registry.refCount(a).?);
    it = fx.registry.assets();
    while (it.next()) |info| {
        try testing.expectEqual(@as(State, if (info.handle.eql(a)) .ready else .pending), info.state);
    }
    try testing.expectError(error.AssetNotFound, fx.registry.complete(fx.gpa, .{ .index = 99, .generation = 1 }));
    try testing.expectEqual(@as(?ContentId, null), fx.registry.idOf(.{ .index = 99, .generation = 1 }));

    while (fx.registry.busy()) {
        manual.runAll();
        _ = fx.registry.pump(fx.gpa, .{});
    }
    try testing.expectEqual(State.ready, fx.registry.state(b).?);
}

test "a pump finishes in request order within its budget, and always finishes its first" {
    const fx = try Fixture.init();
    defer fx.deinit();
    try writeThree(fx);
    var split: FakeSplit = .{};
    try fx.registry.registerLoader(fx.gpa, split.loader(schemas.texture.id));
    var manual = try core.tasks.Manual.init(testing.allocator, 8);
    defer manual.deinit();
    fx.registry.useTasks(manual.tasks());

    var handles: [3]AssetHandle = undefined;
    for (texture_ids, &handles) |id, *h| h.* = try fx.registry.request(fx.gpa, id);
    _ = fx.registry.pump(fx.gpa, .{});
    manual.runAll();

    // One byte of budget: the first finish runs anyway (4 bytes), and nothing after it.
    var stats = fx.registry.pump(fx.gpa, .{ .upload_bytes = 1 });
    try testing.expectEqual(@as(u32, 1), stats.finished);
    try testing.expectEqual(@as(u64, 4), stats.bytes);
    try testing.expectEqual(State.ready, fx.registry.state(handles[0]).?);
    try testing.expectEqual(State.pending, fx.registry.state(handles[1]).?);
    // A finish count of two with bytes to spare: the next two, in order.
    stats = fx.registry.pump(fx.gpa, .{ .max_finishes = 2 });
    try testing.expectEqual(@as(u32, 2), stats.finished);
    try testing.expectEqual(@as(u64, 32), stats.bytes);
    try testing.expectEqual(@as(u32, 0), stats.pending);
}

test "a release to zero while pending cancels it, and the entry goes at the next pump" {
    const fx = try Fixture.init();
    defer fx.deinit();
    try writeThree(fx);
    var split: FakeSplit = .{};
    try fx.registry.registerLoader(fx.gpa, split.loader(schemas.texture.id));
    var manual = try core.tasks.Manual.init(testing.allocator, 8);
    defer manual.deinit();
    fx.registry.useTasks(manual.tasks());

    // Decoding when it was let go.
    const first = try fx.registry.request(fx.gpa, texture_ids[0]);
    _ = fx.registry.pump(fx.gpa, .{});
    fx.registry.release(first);
    try testing.expect(fx.registry.find(texture_ids[0]) == null);
    try testing.expectEqual(@as(u32, 1), fx.registry.count()); // until its decode is done
    // A new request is a new entry, not the cancelled one.
    const second = try fx.registry.request(fx.gpa, texture_ids[0]);
    try testing.expect(!second.eql(first));
    manual.runAll();
    var stats = fx.registry.pump(fx.gpa, .{});
    try testing.expectEqual(@as(u32, 0), stats.finished); // `second` was started this pump
    try testing.expect(fx.registry.state(first) == null);
    try testing.expectEqual(@as(u32, 1), fx.registry.count());
    // The cancelled decode's image was discarded, never finished; only the second's is.
    manual.runAll();
    stats = fx.registry.pump(fx.gpa, .{});
    try testing.expectEqual(@as(u32, 1), stats.finished);
    try testing.expectEqual(@as(u32, 1), split.finishes);

    // Let go before it started: gone at the next pump, having decoded nothing.
    const decodes = split.decodes.load(.monotonic);
    const third = try fx.registry.request(fx.gpa, texture_ids[1]);
    fx.registry.release(third);
    _ = fx.registry.pump(fx.gpa, .{});
    try testing.expect(fx.registry.state(third) == null);
    try testing.expectEqual(decodes, split.decodes.load(.monotonic));
    try testing.expect(!fx.registry.busy());
    fx.registry.release(second);
}

test "quiesce discards work in flight, and a held entry starts again at the next pump" {
    const fx = try Fixture.init();
    defer fx.deinit();
    try writeThree(fx);
    var split: FakeSplit = .{};
    try fx.registry.registerLoader(fx.gpa, split.loader(schemas.texture.id));
    var manual = try core.tasks.Manual.init(testing.allocator, 8);
    defer manual.deinit();
    fx.registry.useTasks(manual.tasks());

    const decoded = try fx.registry.request(fx.gpa, texture_ids[0]);
    const queued = try fx.registry.request(fx.gpa, texture_ids[1]);
    const unstarted = try fx.registry.request(fx.gpa, texture_ids[2]);
    _ = fx.registry.pump(fx.gpa, .{}); // starts all three
    manual.runAt(0); // one decoded, two queued
    const late = try fx.registry.request(fx.gpa, texture_ids[0]); // a second count
    fx.registry.release(late);
    _ = unstarted;

    fx.registry.quiesce();
    // `wait` ran the queued ones; everything they made was thrown away.
    try testing.expect(!fx.registry.busy());
    try testing.expectEqual(@as(u32, 0), manual.pending());
    try testing.expectEqual(@as(u32, 0), split.finishes);
    try testing.expectEqual(State.pending, fx.registry.state(decoded).?);
    try testing.expectEqual(State.pending, fx.registry.state(queued).?);

    // Held, so started again and finished, against the store as it is now.
    _ = fx.registry.pump(fx.gpa, .{});
    try testing.expectEqual(@as(u32, 3), manual.pending());
    manual.runAll();
    const stats = fx.registry.pump(fx.gpa, .{});
    try testing.expectEqual(@as(u32, 3), stats.finished);
    try testing.expectEqual(@as(u32, 1), imageOf(&fx.registry, decoded).?.width);
}

test "a split loader's changed source reloads in the background, keeping the old payload until the new one" {
    const fx = try Fixture.init();
    defer fx.deinit();
    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    var split: FakeSplit = .{};
    try fx.registry.registerLoader(fx.gpa, split.loader(schemas.texture.id));
    var manual = try core.tasks.Manual.init(testing.allocator, 8);
    defer manual.deinit();
    fx.registry.useTasks(manual.tasks());

    const handle = try fx.registry.acquire(fx.gpa, sprites_id);
    defer fx.registry.release(handle);
    try testing.expectEqual(@as(u32, 1), imageOf(&fx.registry, handle).?.width);

    try fx.writeFile("textures/sprites.png", &four_pixel_png);
    try testing.expectEqual(@as(u32, 0), fx.registry.reloadChanged(fx.gpa)); // started, not done
    try testing.expect(fx.registry.busy());
    // Changed again while it is in flight: nothing starts twice; the next pass sees it.
    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    try testing.expectEqual(@as(u32, 0), fx.registry.reloadChanged(fx.gpa));
    try fx.writeFile("textures/sprites.png", &four_pixel_png);
    _ = fx.registry.pump(fx.gpa, .{});
    try testing.expectEqual(@as(u32, 1), manual.pending());
    // Still the old one, and still ready, while the new one decodes.
    try testing.expectEqual(State.ready, fx.registry.state(handle).?);
    try testing.expectEqual(@as(u32, 1), imageOf(&fx.registry, handle).?.width);
    // Unused and with a reload in flight, it is not evicted under that reload.
    const spare = try fx.registry.acquire(fx.gpa, sprites_id);
    fx.registry.release(spare);
    fx.registry.release(handle);
    try testing.expectEqual(@as(u32, 0), fx.registry.evictUnused(fx.gpa));
    try testing.expect(handle.eql(try fx.registry.acquire(fx.gpa, sprites_id)));

    manual.runAll();
    const stats = fx.registry.pump(fx.gpa, .{});
    try testing.expectEqual(@as(u32, 1), stats.reloaded);
    try testing.expectEqual(@as(u32, 2), imageOf(&fx.registry, handle).?.width);
    try testing.expectEqual(@as(u32, 1), split.unloads); // the old one, in the same pump
    try testing.expectEqual(@as(u32, 0), fx.registry.reloadChanged(fx.gpa));
    try testing.expect(!fx.registry.busy());

    // A reload cancelled by `quiesce` has not happened, so the change is seen again.
    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = fx.registry.reloadChanged(fx.gpa);
    try testing.expect(fx.registry.busy());
    fx.registry.quiesce();
    try testing.expect(!fx.registry.busy());
    try testing.expectEqual(@as(u32, 2), imageOf(&fx.registry, handle).?.width);
    _ = fx.registry.reloadChanged(fx.gpa);
    try testing.expect(fx.registry.busy());
    _ = fx.registry.pump(fx.gpa, .{});
    manual.runAll();
    try testing.expectEqual(@as(u32, 1), fx.registry.pump(fx.gpa, .{}).reloaded);
    try testing.expectEqual(@as(u32, 1), imageOf(&fx.registry, handle).?.width);
}

test "a background reload that fails keeps the old payload and says so once" {
    const fx = try Fixture.init();
    defer fx.deinit();
    try fx.writeFile("textures/sprites.png", &one_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    var split: FakeSplit = .{};
    try fx.registry.registerLoader(fx.gpa, split.loader(schemas.texture.id));

    const handle = try fx.registry.acquire(fx.gpa, sprites_id);
    defer fx.registry.release(handle);
    try fx.writeFile("textures/sprites.png", "rubbish, half-saved");
    _ = fx.registry.reloadChanged(fx.gpa);
    const stats = fx.registry.pump(fx.gpa, .{});
    try testing.expectEqual(@as(u32, 1), stats.failed);
    try testing.expectEqual(State.ready, fx.registry.state(handle).?);
    try testing.expectEqual(@as(u32, 1), imageOf(&fx.registry, handle).?.width);
    // The broken file is not retried, and complained about, every pass.
    try testing.expectEqual(@as(u32, 0), fx.registry.reloadChanged(fx.gpa));
    try testing.expect(!fx.registry.busy());

    // A finish that fails is the same: the last payload that worked stays. Synchronously,
    // its decoded image is discarded (`testing.allocator` would report it otherwise).
    try fx.writeFile("textures/sprites.png", &four_pixel_png);
    split.fail_finish = error.LoadFailed;
    try testing.expectError(error.LoadFailed, fx.registry.reload(fx.gpa, handle));
    _ = fx.registry.reloadChanged(fx.gpa);
    try testing.expectEqual(@as(u32, 1), fx.registry.pump(fx.gpa, .{}).failed);
    try testing.expectEqual(@as(u32, 1), imageOf(&fx.registry, handle).?.width);
    try testing.expectEqual(@as(u32, 0), split.unloads);
}

test "a loader nobody split still loads through a request, its load running as the finish" {
    const fx = try Fixture.init();
    defer fx.deinit();
    try fx.writeFile("textures/sprites.png", &four_pixel_png);
    _ = try fx.addPackage("foundry:core", one_texture);
    try fx.registerTextureLoader();
    var manual = try core.tasks.Manual.init(testing.allocator, 8);
    defer manual.deinit();
    fx.registry.useTasks(manual.tasks());

    const handle = try fx.registry.request(fx.gpa, sprites_id);
    defer fx.registry.release(handle);
    _ = fx.registry.pump(fx.gpa, .{});
    manual.runAll();
    try testing.expectEqual(@as(u32, 0), fx.texture_loader.loads); // only read, so far
    const stats = fx.registry.pump(fx.gpa, .{});
    try testing.expectEqual(@as(u32, 1), stats.finished);
    try testing.expectEqual(@as(u64, four_pixel_png.len), stats.bytes); // charged its source
    try testing.expectEqual(@as(u32, 1), fx.texture_loader.loads);
    try testing.expectEqual(@as(u32, 2), fx.payload(handle).width);

    // A private loader is requested the same way, beside it.
    var mine: FakeSplit = .{};
    const private = try fx.registry.requestWith(fx.gpa, sprites_id, mine.loader(schemas.texture.id));
    defer fx.registry.release(private);
    try testing.expect(!private.eql(handle));
    try testing.expect(private.eql(try fx.registry.requestWith(fx.gpa, sprites_id, mine.loader(schemas.texture.id))));
    fx.registry.release(private);
    _ = fx.registry.pump(fx.gpa, .{});
    manual.runAll();
    _ = fx.registry.pump(fx.gpa, .{});
    try testing.expect(fx.registry.getIfLoader(private, mine.loader(schemas.texture.id)) != null);
}

test "deinit quiesces what is in flight, and a loader leaving takes its pending work with it" {
    var split: FakeSplit = .{};
    var manual = try core.tasks.Manual.init(testing.allocator, 8);
    {
        const fx = try Fixture.init();
        defer fx.deinit();
        try writeThree(fx);
        try fx.registry.registerLoader(fx.gpa, split.loader(schemas.texture.id));
        fx.registry.useTasks(manual.tasks());
        _ = try fx.registry.request(fx.gpa, texture_ids[0]);
        _ = try fx.registry.request(fx.gpa, texture_ids[1]);
        _ = fx.registry.pump(fx.gpa, .{});
        // `testing.allocator` checks that the decodes `deinit` waited for were discarded.
    }
    try testing.expectEqual(@as(u32, 0), manual.pending());
    try testing.expectEqual(@as(u32, 0), split.finishes);

    const fx = try Fixture.init();
    defer fx.deinit();
    try writeThree(fx);
    try fx.registry.registerLoader(fx.gpa, split.loader(schemas.texture.id));
    fx.registry.useTasks(manual.tasks());
    const pending = try fx.registry.request(fx.gpa, texture_ids[0]);
    _ = fx.registry.pump(fx.gpa, .{});
    try testing.expectEqual(@as(u32, 1), fx.registry.unregisterLoader(fx.gpa, schemas.texture.id));
    try testing.expect(fx.registry.state(pending) == null);
    try testing.expect(!fx.registry.busy());
    manual.deinit();
}

// -- M27 Step 5: the engine's own split loaders in this module --------------------------

const Executor = enum { immediate, manual_reverse, pool };

/// Requests `id` through `loader` under `executor`, finishes it, and returns the payload
/// re-encoded by `encode`, so two paths' payloads compare as bytes.
fn requestedBytes(fx: *Fixture, id: ContentId, loader: Loader, executor: Executor, encode: *const fn (Allocator, Payload) anyerror![]u8) ![]u8 {
    var manual = try core.tasks.Manual.init(testing.allocator, 4);
    defer manual.deinit();
    const pool = try fx.os.startBackground(testing.allocator, .{ .count = 2 });
    defer pool.deinit();
    switch (executor) {
        .immediate => {},
        .manual_reverse => fx.registry.useTasks(manual.tasks()),
        .pool => fx.registry.useTasks(pool.tasks()),
    }
    const handle = try fx.registry.requestWith(fx.gpa, id, loader);
    defer fx.registry.release(handle);
    while (fx.registry.state(handle).? == .pending) {
        _ = fx.registry.pump(fx.gpa, .{});
        switch (executor) {
            .immediate => {},
            .manual_reverse => while (manual.pending() > 0) manual.runLast(),
            .pool => pool.tasks().wait(),
        }
    }
    try testing.expectEqual(State.ready, fx.registry.state(handle).?);
    const bytes = try encode(fx.gpa, fx.registry.payloadOf(handle).?);
    // Freed here, before the pool and the manual executor it may have used.
    _ = fx.registry.unloadWith(fx.gpa, loader);
    fx.registry.useTasks(core.tasks.immediate);
    return bytes;
}

const skeleton_mod = @import("skeleton.zig");
const animation_mod = @import("animation.zig");
const collision_mod = @import("collision_mesh.zig");
const tilegrid_mod = @import("tilegrid.zig");

const Encoders = struct {
    fn skeleton(gpa: Allocator, payload: Payload) anyerror![]u8 {
        const s = skeleton_mod.fromPayload(payload);
        return skeleton_mod.write(gpa, .{ .parents = s.parents, .rest = s.rest, .inverse_bind = s.inverse_bind, .root = s.root, .names = s.names });
    }
    fn animation(gpa: Allocator, payload: Payload) anyerror![]u8 {
        const a = animation_mod.fromPayload(payload);
        return animation_mod.write(gpa, .{ .duration = a.duration, .joint_count = a.joint_count, .tracks = a.tracks });
    }
    fn collision(gpa: Allocator, payload: Payload) anyerror![]u8 {
        const c = collision_mod.fromPayload(payload);
        return collision_mod.write(gpa, c.positions, c.indices);
    }
    fn tilegrid(gpa: Allocator, payload: Payload) anyerror![]u8 {
        const g = tilegrid_mod.fromPayload(payload);
        return tilegrid_mod.write(gpa, g.width, g.height, g.tiles);
    }
};

test "the skeleton, animation, collision mesh and tile grid loaders make the same payload synchronously and in the background" {
    const gpa = testing.allocator;
    const rests = [_]core.math.Transform{ .{}, .{ .translation = .init(0, 1, 0) } };
    const binds = [_]core.math.Mat4{ .identity, core.math.Mat4.translation(.init(0, -1, 0)) };
    const skel = try skeleton_mod.write(gpa, .{ .parents = &.{ skeleton_mod.no_parent, 0 }, .rest = &rests, .inverse_bind = &binds, .names = &.{ "root", "hand.R" } });
    defer gpa.free(skel);
    const tracks = [_]animation_mod.Track{
        .{ .joint = 0, .path = .translation, .times = &.{ 0, 1 }, .values = &.{ 0, 0, 0, 1, 0, 0 } },
        .{ .joint = 1, .path = .rotation, .interpolation = .step, .times = &.{ 0, 1 }, .values = &.{ 0, 0, 0, 1, 0, 0, 1, 0 } },
    };
    const clip = try animation_mod.write(gpa, .{ .duration = 1, .joint_count = 2, .tracks = &tracks });
    defer gpa.free(clip);
    const positions = [_]core.math.Vec3{ .zero, .init(1, 0, 0), .init(0, 1, 0) };
    const col = try collision_mod.write(gpa, &positions, &.{ 0, 1, 2 });
    defer gpa.free(col);
    const grid = try tilegrid_mod.write(gpa, 3, 2, &.{ 1, 2, 3, 4, 5, 6 });
    defer gpa.free(grid);

    const fx = try Fixture.init();
    defer fx.deinit();
    try fx.writeFile("a.fskel", skel);
    try fx.writeFile("a.fanim", clip);
    try fx.writeFile("a.fcol", col);
    try fx.writeFile("a.fgrid", grid);
    _ = try fx.addPackage("foundry:core",
        \\foundry:skeleton foundry:skeletons.a { source "a.fskel" }
        \\foundry:animation foundry:animations.a { source "a.fanim" }
        \\foundry:collision_mesh foundry:collision.a { source "a.fcol" }
        \\foundry:tilegrid foundry:grids.a { source "a.fgrid" }
    );

    const Case = struct { id: []const u8, loader: Loader, source: []const u8, encode: *const fn (Allocator, Payload) anyerror![]u8 };
    const cases = [_]Case{
        .{ .id = "foundry:skeletons.a", .loader = skeleton_mod.skeletonLoader(), .source = skel, .encode = Encoders.skeleton },
        .{ .id = "foundry:animations.a", .loader = animation_mod.animationLoader(), .source = clip, .encode = Encoders.animation },
        .{ .id = "foundry:collision.a", .loader = collision_mod.collisionMeshLoader(), .source = col, .encode = Encoders.collision },
        .{ .id = "foundry:grids.a", .loader = tilegrid_mod.tilegridLoader(), .source = grid, .encode = Encoders.tilegrid },
    };
    for (cases) |case| {
        try testing.expect(case.loader.split != null);
        const id = ContentId.fromString(case.id);
        // Synchronous: `acquireWith`, which is `loadWhole`.
        const held = try fx.registry.acquireWith(fx.gpa, id, case.loader);
        const sync = try case.encode(gpa, fx.registry.payloadOf(held).?);
        defer gpa.free(sync);
        fx.registry.release(held);
        _ = fx.registry.unloadWith(fx.gpa, case.loader);
        // The payload is its source, re-encoded: nothing was lost in either path.
        try testing.expectEqualSlices(u8, case.source, sync);
        for ([_]Executor{ .immediate, .manual_reverse, .pool }) |executor| {
            const background = try requestedBytes(fx, id, case.loader, executor, case.encode);
            defer gpa.free(background);
            try testing.expectEqualSlices(u8, sync, background);
        }
    }
}

const texture_decode = @import("texture_decode.zig");
const mips = @import("mips.zig");

/// A finish that keeps only what the shared texture decode made: the bytes it would upload,
/// hashed, so a test can compare them with `mips.generate`'s.
const DecodeProbe = struct {
    limits: texture_decode.Limits = .{ .max_dimension = 4096 },

    fn loader(self: *DecodeProbe) Loader {
        return .{
            .schema = schemas.texture.id,
            .ctx = self,
            .load = load,
            .unload = FakeSplit.unload,
            .split = .{ .decode_ctx = &self.limits, .decode = texture_decode.decode, .finish = finish, .discard = texture_decode.discard },
        };
    }

    fn load(ctx: ?*anyopaque, gpa: Allocator, record: Record, bytes: []const u8) LoadError!Payload {
        const self: *DecodeProbe = @ptrCast(@alignCast(ctx.?));
        return self.loader().loadWhole(gpa, record, bytes);
    }

    fn finish(_: ?*anyopaque, gpa: Allocator, _: Record, decoded: Decoded, _: *Budget) LoadError!Payload {
        const texture = texture_decode.of(decoded);
        const bytes = if (texture.chain) |chain| chain.bytes else texture.image.?.pixels;
        const made = try gpa.create(FakeImage);
        made.* = .{ .width = texture.width, .height = texture.height, .sum = std.hash.Fnv1a_64.hash(bytes), .linear = texture.chain != null };
        return .fromPointer(made);
    }
};

test "the shared texture decode makes the chain mips.generate makes, in the record's colour space, either way" {
    const fx = try Fixture.init();
    defer fx.deinit();
    try fx.writeFile("textures/b.png", &four_pixel_png);
    _ = try fx.addPackage("foundry:core",
        \\foundry:texture foundry:textures.data { source "textures/b.png" color_space "linear" mipmaps true }
        \\foundry:texture foundry:textures.colour { source "textures/b.png" mipmaps true }
        \\foundry:texture foundry:textures.flat { source "textures/b.png" }
    );
    var image = try png.decode(testing.allocator, &four_pixel_png, .{});
    defer image.deinit(testing.allocator);
    var linear = try mips.generate(testing.allocator, image, .linear);
    defer linear.deinit(testing.allocator);
    var srgb = try mips.generate(testing.allocator, image, .srgb);
    defer srgb.deinit(testing.allocator);
    // The two spaces average to different bytes, or this test could not tell them apart.
    try testing.expect(!std.mem.eql(u8, linear.bytes, srgb.bytes));

    var probe: DecodeProbe = .{};
    const Case = struct { id: []const u8, bytes: []const u8, chain: bool };
    for ([_]Case{
        .{ .id = "foundry:textures.data", .bytes = linear.bytes, .chain = true },
        .{ .id = "foundry:textures.colour", .bytes = srgb.bytes, .chain = true },
        .{ .id = "foundry:textures.flat", .bytes = image.pixels, .chain = false },
    }) |case| {
        for ([_]bool{ false, true }) |requested| {
            const id = ContentId.fromString(case.id);
            const handle = if (requested) try fx.registry.requestWith(fx.gpa, id, probe.loader()) else try fx.registry.acquireWith(fx.gpa, id, probe.loader());
            _ = fx.registry.pump(fx.gpa, .{});
            const made = imageOf(&fx.registry, handle).?;
            try testing.expectEqual(std.hash.Fnv1a_64.hash(case.bytes), made.sum);
            try testing.expectEqual(case.chain, made.linear);
            fx.registry.release(handle);
            _ = fx.registry.unloadWith(fx.gpa, probe.loader());
        }
    }
}

/// `FakeSplit` with its decoded image returned on the pool, counting each return.
const PoolFreeSplit = struct {
    inner: FakeSplit = .{},
    var frees: std.atomic.Value(u32) = .init(0);

    fn loader(self: *PoolFreeSplit) Loader {
        var made = self.inner.loader(schemas.texture.id);
        made.split.?.discard = discard;
        made.split.?.after_finish = .free_on_pool;
        return made;
    }

    fn discard(gpa: Allocator, decoded: Decoded) void {
        _ = frees.fetchAdd(1, .monotonic);
        FakeSplit.discard(gpa, decoded);
    }
};

test "a split that frees on the pool is ready at its finish, and its decoded value goes on the executor" {
    const fx = try Fixture.init();
    defer fx.deinit();
    try writeThree(fx);
    var split: PoolFreeSplit = .{};
    try fx.registry.registerLoader(fx.gpa, split.loader());
    var manual = try core.tasks.Manual.init(testing.allocator, 8);
    defer manual.deinit();
    fx.registry.useTasks(manual.tasks());
    PoolFreeSplit.frees.store(0, .monotonic);

    const handle = try fx.registry.request(fx.gpa, texture_ids[0]);
    _ = fx.registry.pump(fx.gpa, .{});
    manual.runAll();
    // The finish installs it and is counted; the free is queued, not done on this thread.
    const stats = fx.registry.pump(fx.gpa, .{});
    try testing.expectEqual(@as(u32, 1), stats.finished);
    try testing.expectEqual(State.ready, fx.registry.state(handle).?);
    try testing.expectEqual(@as(u32, 1), manual.pending());
    try testing.expectEqual(@as(u32, 0), PoolFreeSplit.frees.load(.monotonic));
    try testing.expect(fx.registry.busy());
    // The entry no longer waits on the job: released, it is evictable at once, while the
    // free is still queued.
    fx.registry.release(handle);
    try testing.expectEqual(@as(u32, 1), fx.registry.evictUnused(fx.gpa));
    try testing.expect(fx.registry.state(handle) == null);
    manual.runAll();
    try testing.expectEqual(@as(u32, 1), PoolFreeSplit.frees.load(.monotonic));
    // Counted once, at the finish; retired at the next pump.
    try testing.expectEqual(@as(u32, 0), fx.registry.pump(fx.gpa, .{}).finished);
    try testing.expect(!fx.registry.busy());

    // A free still queued when everything is cancelled is done here instead, never lost.
    const other = try fx.registry.request(fx.gpa, texture_ids[1]);
    _ = fx.registry.pump(fx.gpa, .{});
    manual.runAll();
    _ = fx.registry.pump(fx.gpa, .{});
    try testing.expectEqual(State.ready, fx.registry.state(other).?);
    try testing.expectEqual(@as(u32, 1), manual.pending());
    fx.registry.quiesce();
    try testing.expect(!fx.registry.busy());
    try testing.expectEqual(@as(u32, 2), PoolFreeSplit.frees.load(.monotonic));
    try testing.expectEqual(State.ready, fx.registry.state(other).?);

    // Synchronously, `load` frees it at once, on the calling thread.
    const third = try fx.registry.acquire(fx.gpa, texture_ids[2]);
    try testing.expectEqual(@as(u32, 3), PoolFreeSplit.frees.load(.monotonic));
    try testing.expectEqual(State.ready, fx.registry.state(third).?);
}

test "a pool free the executor had no room to start is done when its job is cancelled" {
    const fx = try Fixture.init();
    defer fx.deinit();
    try writeThree(fx);
    var split: PoolFreeSplit = .{};
    try fx.registry.registerLoader(fx.gpa, split.loader());
    // Room for one task, and something else is about to take it.
    var manual = try core.tasks.Manual.init(testing.allocator, 1);
    defer manual.deinit();
    fx.registry.useTasks(manual.tasks());
    PoolFreeSplit.frees.store(0, .monotonic);

    const handle = try fx.registry.request(fx.gpa, texture_ids[0]);
    _ = fx.registry.pump(fx.gpa, .{});
    manual.runAll();
    const Nothing = struct {
        fn call(_: *anyopaque) void {}
    };
    var done: core.tasks.Done = .{};
    var unused: u8 = 0;
    try manual.tasks().start(.{ .context = &unused, .call = Nothing.call }, &done);
    // The finish runs; its free cannot start, the executor being full.
    try testing.expectEqual(@as(u32, 1), fx.registry.pump(fx.gpa, .{}).finished);
    try testing.expectEqual(State.ready, fx.registry.state(handle).?);
    try testing.expectEqual(@as(u32, 0), PoolFreeSplit.frees.load(.monotonic));
    // Cancelled before it ever started: the registry frees it itself, on this thread.
    fx.registry.quiesce();
    try testing.expect(!fx.registry.busy());
    try testing.expectEqual(@as(u32, 1), PoolFreeSplit.frees.load(.monotonic));
    try testing.expectEqual(State.ready, fx.registry.state(handle).?);
    fx.registry.release(handle);
}
