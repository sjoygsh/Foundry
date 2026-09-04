//! The store: many packages, merged into one content set (`docs/design/content-schemas.md`
//! §6–§8).
//!
//! Content IDs in, handles out (I1). A package goes in as bytes and comes out as records
//! addressable by the name someone wrote in a text file, with the package that supplied
//! each one still attached to it.
//!
//! **The store reads compiled packages and nothing else.** Not a parse tree, not a checked
//! `check.Package` — bytes in the `.fpk` format. That is I3 taken literally: `content/core`
//! is compiled and loaded exactly the way a mod is, so there is no privileged path to keep
//! working, because there is only one path. Hot reload in a development build compiles to
//! bytes in memory and comes back through here like everything else.
//!
//! **Merge order is fixed, because I9 depends on it.** §6 pins two orderings:
//!
//! 1. Packages merge in the order they are added — a list supplied from outside, never
//!    discovered. `data` cannot see a filesystem and does not want to.
//! 2. Records merge in the order they appear in a package's record table, which is the
//!    order they appeared in the authoring text with imports inlined where they were used.
//!
//! Those settle *what the merge produces*. What they leave open is where a record that two
//! packages both define sits in iteration, and this store answers: **at the position where
//! it was first defined.** A later package overriding a record replaces the value behind
//! the existing handle without moving it — the same choice the registry makes when a schema
//! is extended (I1), and for the same reason: everything already holding the handle
//! follows. It also means installing a mod that overrides one record does not quietly
//! renumber everything around it.
//!
//! **A record is read against the schema its own package carries**, never against whatever
//! the registry holds now. A record's fields are laid out by field count and field types,
//! so reading a package's bytes with a schema that has since grown a field would not be a
//! stale read — it would be a wrong one. This is why a package carries every schema it uses
//! and not only the ones it declares (§6): the file states the shape it was built against,
//! and that statement outranks the registry's newer copy. Field *indices* still mean the
//! same thing in both, because a version may only append.

const std = @import("std");
const core = @import("core");

const diagnostic = @import("diagnostic.zig");
const fpk = @import("fpk.zig");
const id_mod = @import("id.zig");
const limits_mod = @import("limits.zig");
const schema_mod = @import("schema.zig");
const value_mod = @import("value.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Diagnostics = diagnostic.Diagnostics;
const Limits = limits_mod.Limits;
const Location = diagnostic.Location;
const Registry = schema_mod.Registry;
const Schema = schema_mod.Schema;
const SchemaId = id_mod.SchemaId;
const Value = value_mod.Value;

/// Phantom tags for the two handle spaces (I1).
pub const Packages = opaque {};
pub const PackageHandle = core.Handle(Packages);
pub const Records = opaque {};
pub const RecordHandle = core.Handle(Records);

pub const Error = error{
    /// The package was not merged, and the store is exactly as it was. The diagnostics
    /// say why; this is only the signal, as it is in `check`.
    PackageRejected,
} || Allocator.Error;

/// One loaded package.
pub const LoadedPackage = struct {
    id: ContentId,
    /// The source spelling of `id`, borrowed from the package's own bytes.
    name: []const u8,
    version: u32,
    /// Position in the load order. Zero is the first package added — package zero (I3).
    order: u32,
    /// Where the bytes came from, as the caller described them. **Diagnostics only.** A
    /// path may derive an id at compile time and never means identity (ADR-0021), so
    /// nothing here resolves anything by this string.
    label: []const u8,
    reader: *fpk.Reader,
};

/// One merged record: who it is, who supplied it, and how to read it.
pub const Record = struct {
    handle: RecordHandle,
    id: ContentId,
    schema_id: SchemaId,
    /// The source spelling of `id`, borrowed from the supplying package's bytes.
    name: []const u8,
    /// The package that supplied the definition that won (§7).
    package: PackageHandle,
    /// The schema **as that package carries it**, which is what `fields` is laid out
    /// against. Its version may be older than the registry's.
    schema: Schema,
    fields: fpk.Fields,

    /// The default a *newer* schema version declares for a field this record's package
    /// predates, or null if there is none to fill.
    ///
    /// §3 says loading a record written against an older schema version fills the fields
    /// it does not have from their defaults, and this is that fill: `fields` can only
    /// answer for the fields its own version had, and it reports the rest as absent. The
    /// same shape as `check.Record.value`, which does this for content that has not been
    /// compiled yet.
    pub fn missingDefault(self: Record, newest: Schema, index: u32) ?Value {
        if (index < self.schema.fields.len) return null;
        if (index >= newest.fields.len) return null;
        return switch (newest.fields[index].presence) {
            .default => |d| d,
            else => null,
        };
    }
};

pub const Store = struct {
    /// Holds the labels, and nothing else. Package bytes are borrowed and record fields
    /// are read out of them in place.
    arena: core.Arena,
    limits: Limits,

    packages: core.HandlePool(Packages, LoadedPackage) = .empty,
    /// Package handles in load order — the first of §6's two orderings.
    load_order: std.ArrayList(PackageHandle) = .empty,

    entries: core.HandlePool(Records, Entry) = .empty,
    /// Record handles in merge order — the second, with each record at the position where
    /// it was first defined.
    sequence: std.ArrayList(RecordHandle) = .empty,
    by_id: std.AutoHashMapUnmanaged(u64, RecordHandle) = .empty,

    /// What the store keeps per record: an address, not a copy. The bytes stay in the
    /// package, so an override is four fields written over four fields.
    const Entry = struct {
        id: ContentId,
        schema_id: SchemaId,
        package: PackageHandle,
        /// Position in that package's record table.
        index: u32,
    };

    pub fn init(gpa: Allocator, limits: Limits) Store {
        return .{ .arena = .init(gpa), .limits = limits };
    }

    pub fn deinit(self: *Store, gpa: Allocator) void {
        var it = self.packages.iterator();
        while (it.next()) |entry| {
            entry.value.reader.deinit();
            gpa.destroy(entry.value.reader);
        }
        self.packages.deinit(gpa);
        self.load_order.deinit(gpa);
        self.entries.deinit(gpa);
        self.sequence.deinit(gpa);
        self.by_id.deinit(gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Loads a package and merges its records over what is already here.
    ///
    /// `bytes` is **borrowed for the life of the store**: record fields and every string
    /// in them are read out of it in place, which is the whole point of the format (§5.3).
    /// `label` names where the caller got them, for diagnostics only.
    ///
    /// **All or nothing.** Every fault a package can contain — a header that does not
    /// parse, a schema that conflicts with one already registered, a record naming a
    /// schema the package does not carry, a field whose bytes disagree with the schema, an
    /// id defined twice inside one package — is found before a single record is merged,
    /// and any of them leaves the store untouched. Half a mod's items is a worse outcome
    /// than none of them and a message saying so.
    ///
    /// The one thing not undone is schema registration: a package whose schemas registered
    /// cleanly and whose records did not leaves those schemas in the registry. The registry
    /// has no removal and does not need one — every schema it holds is additive and
    /// nothing reads a schema no record uses.
    pub fn add(
        self: *Store,
        gpa: Allocator,
        label: []const u8,
        bytes: []const u8,
        registry: *Registry,
        diags: *Diagnostics,
    ) Error!PackageHandle {
        const owned_label = try self.arena.allocator().dupe(u8, label);
        const at: Location = .whole(owned_label);

        const reader = try gpa.create(fpk.Reader);
        errdefer gpa.destroy(reader);

        reader.* = fpk.Reader.open(gpa, bytes, self.limits) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsupportedVersion => return self.reject(
                gpa,
                diags,
                at,
                "is a package in format version {d}; this build reads version {d}",
                .{ fpk.versionOf(bytes) orelse 0, fpk.format_version },
            ),
            else => return self.reject(gpa, diags, at, "{s}", .{describeOpenError(err)}),
        };
        errdefer reader.deinit();

        // The name and the id are both in the file and they have to agree, or every
        // answer the store gives about who supplied what is a lie told confidently.
        const spelled = id_mod.contentId(reader.name) catch {
            return self.reject(gpa, diags, at, "names itself '{s}', which is not a valid package name", .{reader.name});
        };
        if (!spelled.eql(reader.id)) {
            return self.reject(gpa, diags, at, "names itself '{s}', which is not the id it carries", .{reader.name});
        }

        if (self.findPackage(reader.id)) |already| {
            return self.reject(
                gpa,
                diags,
                at,
                "'{s}' is already loaded, from {s}; a package appears in the load order once",
                .{ reader.name, self.packages.getConst(already).?.label },
            );
        }

        try self.registerSchemas(gpa, reader, at, registry, diags);

        const handle = try self.packages.add(gpa, .{
            .id = reader.id,
            .name = reader.name,
            .version = reader.version,
            .order = @intCast(self.load_order.items.len),
            .label = owned_label,
            .reader = reader,
        });
        errdefer _ = self.packages.remove(handle);

        try self.validateRecords(gpa, reader, at, diags);

        // Reserved before anything is written, so that the merge below cannot fail after
        // it has begun and leave a package half in.
        try self.load_order.ensureUnusedCapacity(gpa, 1);
        try self.sequence.ensureUnusedCapacity(gpa, reader.record_count);
        try self.entries.ensureUnusedCapacity(gpa, reader.record_count);
        try self.by_id.ensureUnusedCapacity(gpa, reader.record_count);

        var i: u32 = 0;
        while (i < reader.record_count) : (i += 1) {
            const view = reader.record(i).?;
            const entry: Entry = .{
                .id = view.id,
                .schema_id = view.schema_id,
                .package = handle,
                .index = i,
            };
            const slot = self.by_id.getOrPutAssumeCapacity(view.id.hash);
            if (slot.found_existing) {
                // Replace: the whole record, behind the handle it already had.
                self.entries.get(slot.value_ptr.*).?.* = entry;
            } else {
                const record_handle = self.entries.add(gpa, entry) catch unreachable;
                slot.value_ptr.* = record_handle;
                self.sequence.appendAssumeCapacity(record_handle);
            }
        }

        self.load_order.appendAssumeCapacity(handle);
        return handle;
    }

    // --- reading --------------------------------------------------------------

    pub fn packageCount(self: *const Store) u32 {
        return self.packages.count();
    }

    /// Every loaded package, in load order.
    pub fn loadOrder(self: *const Store) []const PackageHandle {
        return self.load_order.items;
    }

    pub fn package(self: *const Store, handle: PackageHandle) ?*const LoadedPackage {
        return self.packages.getConst(handle);
    }

    pub fn findPackage(self: *const Store, package_id: ContentId) ?PackageHandle {
        for (self.load_order.items) |handle| {
            if (self.packages.getConst(handle).?.id.eql(package_id)) return handle;
        }
        return null;
    }

    /// How many distinct content ids the store holds. An overridden record is one record.
    pub fn count(self: *const Store) u32 {
        return self.entries.count();
    }

    pub fn find(self: *const Store, content_id: ContentId) ?RecordHandle {
        return self.by_id.get(content_id.hash);
    }

    pub fn get(self: *const Store, handle: RecordHandle) ?Record {
        const entry = self.entries.getConst(handle) orelse return null;
        const owner = self.packages.getConst(entry.package) orelse return null;
        // Every one of these was resolved before the record was merged, so the fallbacks
        // are unreachable in practice — and are written as fallbacks anyway, because the
        // alternative is an `unreachable` reached by a file rather than by a bug.
        const view = owner.reader.record(entry.index) orelse return null;
        const schema = owner.reader.schemaFor(view.schema_id) orelse return null;
        return .{
            .handle = handle,
            .id = view.id,
            .schema_id = view.schema_id,
            .name = view.name,
            .package = entry.package,
            .schema = schema.*,
            .fields = owner.reader.fieldsOf(view, schema.*),
        };
    }

    /// The common path: a content id straight to a readable record.
    pub fn lookup(self: *const Store, content_id: ContentId) ?Record {
        return self.get(self.find(content_id) orelse return null);
    }

    /// Which package supplied the definition that won (§7).
    pub fn provenance(self: *const Store, handle: RecordHandle) ?PackageHandle {
        return (self.entries.getConst(handle) orelse return null).package;
    }

    /// Every record of one schema, in the merge order of §6.
    pub fn iterate(self: *const Store, schema_id: SchemaId) Iterator {
        return .{ .store = self, .schema_id = schema_id };
    }

    /// Every record, in the merge order of §6.
    pub fn all(self: *const Store) Iterator {
        return .{ .store = self, .schema_id = null };
    }

    /// A linear pass with a filter, deliberately.
    ///
    /// Content iteration happens at load and in tools, not in a frame: a system reading
    /// content in a hot loop holds handles it resolved once, which is what ADR-0005 says
    /// handles are for. An index per schema would be a structure to keep correct across
    /// every override for a cost nobody is paying yet.
    pub const Iterator = struct {
        store: *const Store,
        schema_id: ?SchemaId,
        at: u32 = 0,

        pub fn next(self: *Iterator) ?Record {
            while (self.at < self.store.sequence.items.len) {
                const handle = self.store.sequence.items[self.at];
                self.at += 1;
                const entry = self.store.entries.getConst(handle) orelse continue;
                if (self.schema_id) |wanted| {
                    if (!entry.schema_id.eql(wanted)) continue;
                }
                return self.store.get(handle);
            }
            return null;
        }
    };

    // --- internals ------------------------------------------------------------

    fn reject(
        self: *Store,
        gpa: Allocator,
        diags: *Diagnostics,
        at: Location,
        comptime fmt: []const u8,
        args: anytype,
    ) Error {
        _ = self;
        try diags.addFmt(gpa, .err, at, 1, "", fmt, args);
        return error.PackageRejected;
    }

    fn registerSchemas(
        self: *Store,
        gpa: Allocator,
        reader: *const fpk.Reader,
        at: Location,
        registry: *Registry,
        diags: *Diagnostics,
    ) Error!void {
        _ = self;
        var failed = false;
        for (reader.schemas, reader.schema_names) |schema, name| {
            _ = registry.register(gpa, schema) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    failed = true;
                    try diags.addFmt(
                        gpa,
                        .err,
                        at,
                        1,
                        "",
                        "schema '{s}' {s}",
                        .{ name, schema_mod.describeRegisterError(err) },
                    );
                },
            };
        }
        if (failed) return error.PackageRejected;
    }

    /// Reads every field of every record before merging any of them.
    ///
    /// A package is untrusted input, and every accessor is bounds-safe on its own, so this
    /// is not what makes reading safe — it is what makes a failure *legible*. The
    /// difference is between a package that will not load and a package that loads and then
    /// returns `Malformed` from the tenth field of the thousandth record, three hours in.
    fn validateRecords(
        self: *Store,
        gpa: Allocator,
        reader: *const fpk.Reader,
        at: Location,
        diags: *Diagnostics,
    ) Error!void {
        var scratch: core.Arena = .init(gpa);
        defer scratch.deinit();

        var seen: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        defer seen.deinit(gpa);
        try seen.ensureTotalCapacity(gpa, reader.record_count);

        var failed = false;
        var i: u32 = 0;
        while (i < reader.record_count) : (i += 1) {
            const view = reader.record(i).?;

            if (seen.fetchPutAssumeCapacity(view.id.hash, i)) |first| {
                failed = true;
                try diags.addFmt(gpa, .err, at, 1, "", "'{s}' is defined twice in this package, at records {d} and {d}; overriding happens between packages, not inside one", .{ view.name, first.value, i });
                continue;
            }

            if (self.by_id.get(view.id.hash)) |existing_handle| {
                const existing = self.entries.getConst(existing_handle).?;
                const winner = self.get(existing_handle).?;
                // Two spellings that hash the same is the failure ADR-0005 requires be an
                // error naming both, rather than one record silently becoming another.
                if (!std.mem.eql(u8, winner.name, view.name)) {
                    failed = true;
                    try diags.addFmt(gpa, .err, at, 1, "", "'{s}' and '{s}' from {s} hash to the same content id", .{ view.name, winner.name, self.packages.getConst(existing.package).?.name });
                    continue;
                }
                // Overriding a record is restating it, and a restatement of a different
                // schema is not the same record wearing a hat: everything that iterated
                // the old schema would silently stop seeing it.
                if (!existing.schema_id.eql(view.schema_id)) {
                    failed = true;
                    try diags.addFmt(gpa, .err, at, 1, "", "'{s}' overrides the record from {s} with a different schema; an override restates a record, it does not retype it", .{ view.name, self.packages.getConst(existing.package).?.name });
                    continue;
                }
            }

            const schema = reader.schemaFor(view.schema_id) orelse {
                failed = true;
                try diags.addFmt(gpa, .err, at, 1, "", "'{s}' names schema {f}, which the package does not carry", .{ view.name, view.schema_id });
                continue;
            };

            scratch.reset();
            const fields = reader.fieldsOf(view, schema.*);
            for (0..schema.fields.len) |index| {
                _ = fields.valueAt(scratch.allocator(), @intCast(index)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        failed = true;
                        try diags.addFmt(gpa, .err, at, 1, "", "'{s}' has a field {d} the package's own bytes cannot produce: {s}", .{ view.name, index, @errorName(err) });
                        break;
                    },
                };
            }
        }
        if (failed) return error.PackageRejected;
    }
};

fn describeOpenError(err: fpk.OpenError) []const u8 {
    return switch (err) {
        error.NotAPackage => "is not a package: it does not start with a package header",
        error.UnsupportedVersion => "is a package in a format version this build does not read",
        error.UnsupportedFlags => "sets a package flag this build does not know, and a flag changes how bytes are read",
        error.Malformed => "is a package whose own offsets and lengths do not agree with its size",
        error.InvalidUtf8 => "is a package whose strings are not valid UTF-8",
        error.TooManyFields => "declares a schema with more fields than the limit allows",
        error.NestingTooDeep => "declares a schema that nests deeper than the limit allows",
        error.OutOfMemory => "could not be read: out of memory",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const check = @import("check.zig");
const parser = @import("parser.zig");

/// Compiles source into package bytes, the way `fpack` will, and throws away everything
/// but the bytes — so every test here proves the store needs nothing but a `.fpk`.
fn compile(gpa: Allocator, name: []const u8, source: []const u8, out: *std.ArrayList(u8)) !void {
    var registry: Registry = .init(gpa, .default);
    defer registry.deinit(gpa);
    var diags: Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    try compileWith(gpa, name, source, &registry, &diags, out);
}

/// The same, against a registry the caller supplies — for the tests that need two packages
/// compiled against one set of schemas, which is what a mod is.
fn compileWith(
    gpa: Allocator,
    name: []const u8,
    source: []const u8,
    registry: *Registry,
    diags: *Diagnostics,
    out: *std.ArrayList(u8),
) !void {
    var doc = try parser.parse(gpa, "test.fdt", source, .{
        .namespace = name[0..std.mem.indexOfScalar(u8, name, ':').?],
    }, diags);
    defer doc.deinit(gpa);

    var pkg = try check.Package.init(gpa, name, 1, .default);
    defer pkg.deinit(gpa);
    try pkg.addDocument(gpa, &doc, registry, diags);

    try fpk.write(gpa, &pkg, registry, out);
}

const Harness = struct {
    gpa: Allocator,
    registry: Registry,
    diags: Diagnostics,
    store: Store,
    blobs: std.ArrayList(std.ArrayList(u8)) = .empty,

    fn init() Harness {
        const gpa = testing.allocator;
        return .{
            .gpa = gpa,
            .registry = .init(gpa, .default),
            .diags = .init(gpa, .default),
            .store = .init(gpa, .default),
        };
    }

    fn deinit(self: *Harness) void {
        self.store.deinit(self.gpa);
        self.registry.deinit(self.gpa);
        self.diags.deinit(self.gpa);
        for (self.blobs.items) |*b| b.deinit(self.gpa);
        self.blobs.deinit(self.gpa);
    }

    /// Compiles a package against its own private registry — two independent packages, the
    /// way two authors who never met would produce them.
    fn compileAlone(self: *Harness, name: []const u8, source: []const u8) ![]const u8 {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(self.gpa);
        try compile(self.gpa, name, source, &bytes);
        try self.blobs.append(self.gpa, bytes);
        return self.blobs.items[self.blobs.items.len - 1].items;
    }

    fn load(self: *Harness, label: []const u8, bytes: []const u8) !PackageHandle {
        return self.store.add(self.gpa, label, bytes, &self.registry, &self.diags);
    }

    fn add(self: *Harness, name: []const u8, source: []const u8) !PackageHandle {
        const bytes = try self.compileAlone(name, source);
        return self.load(name, bytes);
    }

    fn rendered(self: *Harness, buf: []u8) ![]const u8 {
        var writer: std.Io.Writer = .fixed(buf);
        try self.diags.render(&writer);
        return writer.buffered();
    }
};

const core_source =
    \\@schema item { name string  weight f32 (default 1.0) }
    \\item foundry:item.torch { name "Torch"  weight 0.5 }
    \\item foundry:item.rope  { name "Rope"   weight 2.0 }
;

test "a package loads, and its records are addressable by the name someone wrote" {
    var h: Harness = .init();
    defer h.deinit();

    const pkg = try h.add("foundry:core", core_source);
    try testing.expectEqual(@as(u32, 1), h.store.packageCount());
    try testing.expectEqual(@as(u32, 2), h.store.count());
    try testing.expectEqualStrings("foundry:core", h.store.package(pkg).?.name);
    try testing.expectEqual(@as(u32, 0), h.store.package(pkg).?.order);

    const torch = h.store.lookup(try id_mod.contentId("foundry:item.torch")).?;
    try testing.expectEqualStrings("foundry:item.torch", torch.name);
    try testing.expectEqualStrings("Torch", (try torch.fields.stringAt(0)).?);
    try testing.expectEqual(@as(f64, 0.5), (try torch.fields.floatAt(1)).?);
    try testing.expect(torch.package.eql(pkg));

    try testing.expect(h.store.find(try id_mod.contentId("foundry:item.lantern")) == null);
}

test "a later package overrides by id, and the store remembers who won" {
    var h: Harness = .init();
    defer h.deinit();

    const core_pkg = try h.add("foundry:core", core_source);

    // A mod compiled against the schemas it uses, the way `fpack` will compile one.
    var mod_bytes: std.ArrayList(u8) = .empty;
    defer mod_bytes.deinit(h.gpa);
    {
        var registry: Registry = .init(h.gpa, .default);
        defer registry.deinit(h.gpa);
        var diags: Diagnostics = .init(h.gpa, .default);
        defer diags.deinit(h.gpa);
        try compileWith(h.gpa, "foundry:core", core_source, &registry, &diags, &mod_bytes);
        mod_bytes.clearRetainingCapacity();
        try compileWith(h.gpa, "heavy:mod",
            \\foundry:item foundry:item.torch { name "Torch"  weight 9.0 }
            \\foundry:item heavy:item.anvil   { name "Anvil"  weight 90.0 }
        , &registry, &diags, &mod_bytes);
        try testing.expect(!diags.failed);
    }

    const mod_pkg = try h.load("heavy:mod", mod_bytes.items);

    // Two packages, three records: the torch is one record that changed hands.
    try testing.expectEqual(@as(u32, 2), h.store.packageCount());
    try testing.expectEqual(@as(u32, 3), h.store.count());

    const torch_id = try id_mod.contentId("foundry:item.torch");
    const torch = h.store.lookup(torch_id).?;
    try testing.expectEqual(@as(f64, 9.0), (try torch.fields.floatAt(1)).?);
    try testing.expect(h.store.provenance(torch.handle).?.eql(mod_pkg));

    // The record the mod left alone still comes from where it came from.
    const rope = h.store.lookup(try id_mod.contentId("foundry:item.rope")).?;
    try testing.expect(h.store.provenance(rope.handle).?.eql(core_pkg));
    try testing.expectEqualStrings("foundry:core", h.store.package(rope.package).?.name);
}

test "an override keeps the record's handle and its place in the merge order" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.add("foundry:core", core_source);
    const torch_id = try id_mod.contentId("foundry:item.torch");
    const before = h.store.find(torch_id).?;

    var mod_bytes: std.ArrayList(u8) = .empty;
    defer mod_bytes.deinit(h.gpa);
    {
        var registry: Registry = .init(h.gpa, .default);
        defer registry.deinit(h.gpa);
        var diags: Diagnostics = .init(h.gpa, .default);
        defer diags.deinit(h.gpa);
        try compileWith(h.gpa, "foundry:core", core_source, &registry, &diags, &mod_bytes);
        mod_bytes.clearRetainingCapacity();
        try compileWith(h.gpa, "heavy:mod",
            \\foundry:item heavy:item.anvil   { name "Anvil"  weight 90.0 }
            \\foundry:item foundry:item.torch { name "Torch"  weight 9.0 }
        , &registry, &diags, &mod_bytes);
    }
    _ = try h.load("heavy:mod", mod_bytes.items);

    // The handle survives the override, the way a schema handle survives an extension.
    try testing.expect(before.eql(h.store.find(torch_id).?));

    // And the torch is still first: a record sits where it was first defined, so
    // installing a mod does not renumber what it did not touch.
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(h.gpa);
    var it = h.store.all();
    while (it.next()) |record| {
        try names.appendSlice(h.gpa, record.name);
        try names.append(h.gpa, ' ');
    }
    try testing.expectEqualStrings(
        "foundry:item.torch foundry:item.rope heavy:item.anvil ",
        names.items,
    );
}

test "iteration by schema visits every record of one schema, and only those" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.add("foundry:core",
        \\@schema item { name string }
        \\@schema tile { solid bool }
        \\item foundry:item.torch { name "Torch" }
        \\tile foundry:tile.wall  { solid true }
        \\item foundry:item.rope  { name "Rope" }
    );

    var count: u32 = 0;
    var it = h.store.iterate(try SchemaId.parse("foundry:item"));
    while (it.next()) |record| : (count += 1) {
        try testing.expect(record.schema_id.eql(try SchemaId.parse("foundry:item")));
    }
    try testing.expectEqual(@as(u32, 2), count);
    try testing.expectEqual(@as(u32, 3), h.store.count());

    // A schema nobody declared iterates empty rather than failing.
    var none = h.store.iterate(try SchemaId.parse("foundry:nothing"));
    try testing.expect(none.next() == null);
}

test "two packages that share a schema each carry it, and the registry takes the newest" {
    var h: Harness = .init();
    defer h.deinit();

    // Independently compiled: neither author saw the other's registry.
    _ = try h.add("foundry:core",
        \\@schema item { name string }
        \\item foundry:item.torch { name "Torch" }
    );
    _ = try h.add("heavy:mod",
        \\@schema foundry:item { name string  weight f32 (since 2) (default 1.0) }
        \\foundry:item foundry:item.anvil { name "Anvil"  weight 90.0 }
    );

    // One schema in the registry, at the version the extension brought.
    try testing.expectEqual(@as(u32, 1), h.registry.count());
    const item = h.registry.lookup(try SchemaId.parse("foundry:item")).?;
    try testing.expectEqual(@as(u32, 2), item.version);
    try testing.expectEqual(@as(usize, 2), item.fields.len);

    // The mod's record is laid out for two fields and reads both...
    const anvil = h.store.lookup(try id_mod.contentId("foundry:item.anvil")).?;
    try testing.expectEqual(@as(u32, 2), anvil.schema.version);
    try testing.expectEqual(@as(f64, 90.0), (try anvil.fields.floatAt(1)).?);

    // ...and the base game's record is laid out for one, is read as one, and answers for
    // the field it predates out of the newer schema's default. Reading it against the
    // registry's copy instead would have read a field that is not in its bytes.
    const torch = h.store.lookup(try id_mod.contentId("foundry:item.torch")).?;
    try testing.expectEqual(@as(u32, 1), torch.schema.version);
    try testing.expectEqual(@as(u32, 1), torch.fields.count());
    try testing.expect((try torch.fields.floatAt(1)) == null);
    try testing.expectEqual(@as(f64, 1.0), torch.missingDefault(item.*, 1).?.float);
    try testing.expect(torch.missingDefault(item.*, 0) == null);
}

test "two packages that disagree about one schema are refused, and the store is untouched" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.add("foundry:core",
        \\@schema item { name string }
        \\item foundry:item.torch { name "Torch" }
    );
    try testing.expectError(error.PackageRejected, h.add("heavy:mod",
        \\@schema foundry:item { weight f32 }
        \\foundry:item foundry:item.anvil { weight 90.0 }
    ));

    try testing.expectEqual(@as(u32, 1), h.store.packageCount());
    try testing.expectEqual(@as(u32, 1), h.store.count());

    var buf: [1024]u8 = undefined;
    const text = try h.rendered(&buf);
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "heavy:mod: error:"));
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "with a different declaration"));
}

test "the same package twice is a load-order mistake, named as one" {
    var h: Harness = .init();
    defer h.deinit();

    const bytes = try h.compileAlone("foundry:core", core_source);
    _ = try h.load("content/core.fpk", bytes);
    try testing.expectError(error.PackageRejected, h.load("mods/core-copy.fpk", bytes));

    try testing.expectEqual(@as(u32, 1), h.store.packageCount());
    var buf: [1024]u8 = undefined;
    const text = try h.rendered(&buf);
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "already loaded, from content/core.fpk"));
}

test "an override that changes the schema is refused" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.add("foundry:core",
        \\@schema item { name string }
        \\item foundry:item.torch { name "Torch" }
    );
    try testing.expectError(error.PackageRejected, h.add("heavy:mod",
        \\@schema tile { solid bool }
        \\tile foundry:item.torch { solid true }
    ));

    // Nothing of the rejected package is in the store, including its schema-only records.
    try testing.expectEqual(@as(u32, 1), h.store.count());
    const torch = h.store.lookup(try id_mod.contentId("foundry:item.torch")).?;
    try testing.expectEqualStrings("Torch", (try torch.fields.stringAt(0)).?);

    var buf: [1024]u8 = undefined;
    const text = try h.rendered(&buf);
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "it does not retype it"));
}

test "a package rejected for its records leaves no records behind" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.add("foundry:core", core_source);

    // A package whose second record is the problem: the first must not survive it.
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(h.gpa);
    {
        var registry: Registry = .init(h.gpa, .default);
        defer registry.deinit(h.gpa);
        var diags: Diagnostics = .init(h.gpa, .default);
        defer diags.deinit(h.gpa);
        try compileWith(h.gpa, "foundry:core", core_source, &registry, &diags, &bytes);
        bytes.clearRetainingCapacity();
        try compileWith(h.gpa, "heavy:mod",
            \\foundry:item heavy:item.anvil { name "Anvil"  weight 90.0 }
            \\foundry:item heavy:item.nail  { name "Nail"   weight 0.01 }
        , &registry, &diags, &bytes);
    }

    // Corrupt the second record's field block so that reading it fails, without touching
    // anything `open` checks.
    const records_offset = std.mem.readInt(u32, bytes.items[40..44], .little);
    const second = records_offset + 32;
    std.mem.writeInt(u32, bytes.items[second + 28 ..][0..4], 1, .little); // block_len = 1

    try testing.expectError(error.PackageRejected, h.load("heavy:mod", bytes.items));
    try testing.expectEqual(@as(u32, 2), h.store.count());
    try testing.expect(h.store.find(try id_mod.contentId("heavy:item.anvil")) == null);
    try testing.expectEqual(@as(u32, 1), h.store.packageCount());
}

test "a file that is not a package says so, in the terms the format promised" {
    var h: Harness = .init();
    defer h.deinit();

    try testing.expectError(error.PackageRejected, h.load("junk.fpk", "not a package at all"));

    var future: [fpk.header_size]u8 = @splat(0);
    @memcpy(future[0..4], fpk.magic);
    std.mem.writeInt(u32, future[4..8], 7, .little);
    try testing.expectError(error.PackageRejected, h.load("future.fpk", &future));

    var buf: [1024]u8 = undefined;
    const text = try h.rendered(&buf);
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "junk.fpk: error: is not a package"));
    try testing.expect(std.mem.containsAtLeast(u8, text, 1, "format version 7; this build reads version 1"));
}

test "the merge is a pure function of the packages and their order" {
    const gpa = testing.allocator;

    const sources: [3][]const u8 = .{
        \\foundry:item foundry:item.torch { name "Torch"  weight 0.5 }
        \\foundry:item foundry:item.rope  { name "Rope"   weight 2.0 }
        ,
        \\foundry:item foundry:item.torch { name "Bright Torch"  weight 0.6 }
        ,
        \\foundry:item foundry:item.rope  { name "Strong Rope"  weight 3.0 }
        \\foundry:item foundry:item.torch { name "Heavy Torch"  weight 9.0 }
        ,
    };

    // Two independent runs of the same load order, each from its own bytes.
    var seen: [2][]const u8 = undefined;
    var buffers: [2]std.ArrayList(u8) = .{ .empty, .empty };
    defer for (&buffers) |*b| b.deinit(gpa);

    for (0..2) |run| {
        var h: Harness = .init();
        defer h.deinit();

        _ = try h.add("foundry:core", core_source);
        for (sources, 0..) |source, i| {
            var registry: Registry = .init(gpa, .default);
            defer registry.deinit(gpa);
            var diags: Diagnostics = .init(gpa, .default);
            defer diags.deinit(gpa);

            var bytes: std.ArrayList(u8) = .empty;
            errdefer bytes.deinit(gpa);
            try compileWith(gpa, "foundry:core", core_source, &registry, &diags, &bytes);
            bytes.clearRetainingCapacity();

            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "mod{d}:pack", .{i});
            try compileWith(gpa, name, source, &registry, &diags, &bytes);
            try h.blobs.append(gpa, bytes);
            _ = try h.load(name, h.blobs.items[h.blobs.items.len - 1].items);
        }

        var out = &buffers[run];
        var it = h.store.all();
        while (it.next()) |record| {
            try out.appendSlice(gpa, record.name);
            try out.append(gpa, '=');
            try out.appendSlice(gpa, (try record.fields.stringAt(0)).?);
            try out.append(gpa, '@');
            try out.appendSlice(gpa, h.store.package(record.package).?.name);
            try out.append(gpa, '\n');
        }
        seen[run] = out.items;
    }

    try testing.expectEqualStrings(seen[0], seen[1]);
    try testing.expectEqualStrings(
        \\foundry:item.torch=Heavy Torch@mod2:pack
        \\foundry:item.rope=Strong Rope@mod2:pack
        \\
    , seen[0]);
}
