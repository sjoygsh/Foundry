//! `.fsav` — a world on disk (`docs/design/entity-storage.md` §9).
//!
//! **Not a package.** Reusing `.fpk` would mean giving every entity a content ID, and a
//! generated `save:entity.00417` is an identity derived from position — the precise
//! anti-pattern I2 exists to forbid. Content IDs name authored things; entities are not
//! authored. So this is its own format, with its own magic and its version in a field
//! rather than in the magic, which is the same discipline `.fpk` keeps for the same I8
//! reason.
//!
//! What it does share is everything below the container: the field-block layout and the
//! schema encoding are `data.fpk`'s, so a component's fields are laid out byte for byte the
//! way a record's are, against the same schema, with the same versioning rule.
//!
//! **Entity identity is preserved exactly.** A reloaded world hands out the same handles the
//! original would have, including the generations of slots that are free — so an `Entity`
//! stored inside a component's data is still correct with no remapping pass. That is what
//! keeps `scene` from having to know which fields are entity references, a fact that would
//! otherwise live in two places and be wrong in a mod's components first.
//!
//! **The reader trusts nothing.** Counts are bounded before allocation, every offset is
//! checked against the file's length, every owner entity is checked against the pool the
//! same file just described, and a component type this build does not know is reported and
//! skipped rather than fatal — a save from a session with a mod loaded opens without it,
//! minus that mod's components.

const std = @import("std");
const core = @import("core");
const data = @import("data");

const component = @import("component.zig");
const entity_mod = @import("entity.zig");
const world_mod = @import("world.zig");

const Allocator = std.mem.Allocator;
const Entities = entity_mod.Entities;
const Entity = entity_mod.Entity;
const Field = data.Field;
const World = world_mod.World;
const log = core.log.scoped(.scene);

// ---------------------------------------------------------------------------
// The format
// ---------------------------------------------------------------------------

pub const magic = "FSAV";

/// Bumped when the layout below changes. In a field, not in the magic, so a save from a
/// future Foundry reports "save format 3, this build understands 1" rather than "not a
/// save" — the practical value of I8 at a file boundary.
pub const format_version: u32 = 1;

/// ```
/// 0   magic            [4]u8   "FSAV"
/// 4   format_version   u32
/// 8   flags            u32     must be zero
/// 12  type_count       u32
/// 16  slot_count       u32     entity pool slots, live and free alike
/// 20  free_count       u32
/// 24  types_offset     u32     type entries, then their field declarations
/// 28  types_len        u32
/// 32  slots_offset     u32     slot_count fixed entries
/// 36  slots_len        u32
/// 40  free_offset      u32     free_count u32 slot indices, head first
/// 44  free_len         u32
/// 48  owners_offset    u32     each store's dense owner array, in dense order
/// 52  owners_len       u32
/// 56  fields_offset    u32     packed component blocks
/// 60  fields_len       u32
/// 64  strings_offset   u32     schema and field names
/// 68  strings_len      u32
/// ```
pub const header_size = 72;

/// ```
/// 0   schema_id        u64
/// 8   version          u32
/// 12  name_offset      u32     the type's spelling, for diagnostics
/// 16  name_len         u32
/// 20  decl_offset      u32     into the declarations after the entries
/// 24  dense_count      u32     how many entities have this component
/// 28  owners_offset    u32     into the owners section
/// 32  blocks_offset    u32     into the fields section
/// 36  reserved         u32     must be zero
/// ```
const type_entry_size = 40;

/// A slot's generation, and whether it is occupied.
///
/// Occupancy is stated even though the free list already implies it, so that the two can
/// be cross-checked: a file whose free list disagrees with its slots is refused rather than
/// producing a pool that hands out a handle somebody is still holding.
const slot_entry_size = 8;

const section_align = 8;

/// The format version of `bytes`, or null if it is not a save at all.
pub fn versionOf(bytes: []const u8) ?u32 {
    if (bytes.len < header_size) return null;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return null;
    return std.mem.readInt(u32, bytes[4..8], .little);
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

pub const WriteError = error{
    /// A save past the format's 32-bit offsets — four gigabytes of one world.
    SaveTooLarge,
    /// A component type's `serialize` disagreed with its own schema, which is a
    /// registration bug rather than a data one.
    ComponentNotSerializable,
} || Allocator.Error;

/// Writes `world` into `out`.
///
/// **Order is fixed and documented** (I9): component types in ascending type-handle index,
/// each store's components in dense order, entity slots in slot-index order, and the free
/// list in the order `add` will consume it. That is what makes a reloaded world iterate the
/// way the original did (§5) and two saves of the same world byte-identical.
///
/// A component type without both halves of its codec is **left out**, and so are its
/// components. `Registration.savable` is the rule and it is the type's own decision.
pub fn write(world: *World, gpa: Allocator, out: *std.ArrayList(u8)) WriteError!void {
    var b: Builder = .{ .gpa = gpa, .blocks = .{ .gpa = gpa }, .schemas = undefined };
    b.schemas = .{ .gpa = gpa, .blocks = &b.blocks };
    defer b.deinit();

    var types = world.types.iterator();
    while (types.next()) |entry| {
        const reg = entry.value;
        if (!reg.savable()) continue;
        // The schema as the registry holds it *now*: a package may have extended it, and
        // the blocks are laid out against the shape the file also carries.
        const schema = world.schemas.get(reg.schema) orelse continue;
        try b.addType(world, entry.id, reg.*, schema.*);
    }

    var slot: u32 = 0;
    while (world.entities.slotAt(slot)) |state| : (slot += 1) {
        try appendU32(gpa, &b.slots, state.generation);
        try appendU32(gpa, &b.slots, @intFromBool(state.value != null));
    }
    var free = world.entities.freeSlots();
    while (free.next()) |index| try appendU32(gpa, &b.free, index);

    try b.assemble(slot, out);
}

const Builder = struct {
    gpa: Allocator,
    blocks: data.BlockWriter,
    schemas: data.SchemaWriter,
    entries: std.ArrayList(u8) = .empty,
    slots: std.ArrayList(u8) = .empty,
    free: std.ArrayList(u8) = .empty,
    owners: std.ArrayList(u8) = .empty,
    type_count: u32 = 0,
    free_count: u32 = 0,

    fn deinit(self: *Builder) void {
        self.schemas.deinit();
        self.blocks.deinit();
        self.entries.deinit(self.gpa);
        self.slots.deinit(self.gpa);
        self.free.deinit(self.gpa);
        self.owners.deinit(self.gpa);
        self.* = undefined;
    }

    fn addType(
        self: *Builder,
        world: *World,
        handle: component.ComponentType,
        reg: component.Registration,
        schema: data.Schema,
    ) WriteError!void {
        const store = &world.stores.items[handle.index];
        const count = store.count();

        const decl_offset = self.schemas.add(schema.fields) catch |err| return mapBlock(err, reg.name);
        const owners_offset = try cast32(self.owners.items.len);
        const blocks_offset = self.blocks.beginArray(schema.fields, count) catch |err| return mapBlock(err, reg.name);

        var dense: u32 = 0;
        while (dense < count) : (dense += 1) {
            try appendU64(self.gpa, &self.owners, store.ownerAt(dense).bits());
            const block = self.blocks.blockIn(blocks_offset, schema.fields, dense);
            reg.serialize.?(reg.ctx, store.at(dense).ptr, block) catch |err| {
                return mapBlock(err, reg.name);
            };
        }

        const name_ref = self.blocks.intern(reg.name) catch |err| return mapBlock(err, reg.name);
        try appendU64(self.gpa, &self.entries, schema.id.hash);
        try appendU32(self.gpa, &self.entries, schema.version);
        try appendU32(self.gpa, &self.entries, name_ref.offset);
        try appendU32(self.gpa, &self.entries, name_ref.len);
        try appendU32(self.gpa, &self.entries, decl_offset);
        try appendU32(self.gpa, &self.entries, count);
        try appendU32(self.gpa, &self.entries, owners_offset);
        try appendU32(self.gpa, &self.entries, blocks_offset);
        try appendU32(self.gpa, &self.entries, 0); // reserved
        self.type_count += 1;
    }

    fn assemble(self: *Builder, slot_count: u32, out: *std.ArrayList(u8)) WriteError!void {
        const types_len = try cast32(self.entries.items.len + self.schemas.decls.items.len);
        const slots_len = try cast32(self.slots.items.len);
        const free_len = try cast32(self.free.items.len);
        const owners_len = try cast32(self.owners.items.len);
        const fields_len = try cast32(self.blocks.fields.items.len);
        const strings_len = try cast32(self.blocks.strings.items.len);

        const types_offset: u32 = header_size;
        const slots_offset = alignUp(try addU32(types_offset, types_len));
        const free_offset = alignUp(try addU32(slots_offset, slots_len));
        const owners_offset = alignUp(try addU32(free_offset, free_len));
        const fields_offset = alignUp(try addU32(owners_offset, owners_len));
        const strings_offset = alignUp(try addU32(fields_offset, fields_len));
        const total = try addU32(strings_offset, strings_len);

        try out.ensureUnusedCapacity(self.gpa, total);
        const start = out.items.len;

        var header: [header_size]u8 = @splat(0);
        @memcpy(header[0..4], magic);
        std.mem.writeInt(u32, header[4..8], format_version, .little);
        std.mem.writeInt(u32, header[8..12], 0, .little); // flags
        std.mem.writeInt(u32, header[12..16], self.type_count, .little);
        std.mem.writeInt(u32, header[16..20], slot_count, .little);
        std.mem.writeInt(u32, header[20..24], free_len / 4, .little);
        std.mem.writeInt(u32, header[24..28], types_offset, .little);
        std.mem.writeInt(u32, header[28..32], types_len, .little);
        std.mem.writeInt(u32, header[32..36], slots_offset, .little);
        std.mem.writeInt(u32, header[36..40], slots_len, .little);
        std.mem.writeInt(u32, header[40..44], free_offset, .little);
        std.mem.writeInt(u32, header[44..48], free_len, .little);
        std.mem.writeInt(u32, header[48..52], owners_offset, .little);
        std.mem.writeInt(u32, header[52..56], owners_len, .little);
        std.mem.writeInt(u32, header[56..60], fields_offset, .little);
        std.mem.writeInt(u32, header[60..64], fields_len, .little);
        std.mem.writeInt(u32, header[64..68], strings_offset, .little);
        std.mem.writeInt(u32, header[68..72], strings_len, .little);
        try out.appendSlice(self.gpa, &header);

        try out.appendSlice(self.gpa, self.entries.items);
        try out.appendSlice(self.gpa, self.schemas.decls.items);
        try padTo(self.gpa, out, start, slots_offset);
        try out.appendSlice(self.gpa, self.slots.items);
        try padTo(self.gpa, out, start, free_offset);
        try out.appendSlice(self.gpa, self.free.items);
        try padTo(self.gpa, out, start, owners_offset);
        try out.appendSlice(self.gpa, self.owners.items);
        try padTo(self.gpa, out, start, fields_offset);
        try out.appendSlice(self.gpa, self.blocks.fields.items);
        try padTo(self.gpa, out, start, strings_offset);
        try out.appendSlice(self.gpa, self.blocks.strings.items);
    }
};

/// `data`'s block errors, in this file's vocabulary.
///
/// `ValueTypeMismatch` out of a serializer means the component type's own writer cannot
/// express the component type's own schema, which is a registration bug — so it is named
/// for what it is rather than passed through as a layout error.
fn mapBlock(err: data.fpk.BlockError, name: []const u8) WriteError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooLarge => error.SaveTooLarge,
        error.ValueTypeMismatch => {
            log.warn("component type '{s}' cannot serialize against its own schema", .{name});
            return error.ComponentNotSerializable;
        },
    };
}

fn alignUp(v: u32) u32 {
    return (v + section_align - 1) & ~@as(u32, section_align - 1);
}

fn cast32(v: usize) WriteError!u32 {
    return std.math.cast(u32, v) orelse error.SaveTooLarge;
}

fn addU32(a: u32, b: u32) WriteError!u32 {
    const sum, const overflow = @addWithOverflow(a, b);
    if (overflow != 0) return error.SaveTooLarge;
    return sum;
}

fn padTo(gpa: Allocator, out: *std.ArrayList(u8), start: usize, offset: u32) Allocator.Error!void {
    const written = out.items.len - start;
    if (written < offset) try out.appendNTimes(gpa, 0, offset - written);
}

fn appendU32(gpa: Allocator, out: *std.ArrayList(u8), v: u32) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}

fn appendU64(gpa: Allocator, out: *std.ArrayList(u8), v: u64) Allocator.Error!void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

pub const ReadError = error{
    /// Too short, or the magic is not `FSAV`. Ask `versionOf` before reporting this.
    NotASave,
    SaveUnsupportedVersion,
    /// A flag bit this build does not know. Flags change how bytes are read, so an
    /// unknown one is refused rather than ignored.
    SaveUnsupportedFlags,
    /// The file disagrees with itself: an offset, a count, an owner entity the file's own
    /// pool does not have, or a slot table its free list contradicts.
    SaveCorrupt,
    /// Loading into a world that already has entities. A caller mistake rather than a bad
    /// file — a save carries absolute handles, so merging it into a populated world is a
    /// different operation with different rules (§9, and §13's fifth open question).
    WorldNotEmpty,
} || Allocator.Error;

/// What a load found, and what it left out.
pub const Summary = struct {
    /// Live entities restored. Free slots are restored too and are not counted here.
    entities: u32 = 0,
    components: u32 = 0,
    /// Component types the file carries that this build did not load: no type registered
    /// for that schema ID, no deserializer, or a schema that disagrees with the registered
    /// one. Their components are absent from the loaded world, which is the point — a save
    /// from a session with a mod loaded opens without it.
    skipped_types: u32 = 0,
};

/// Loads a save into a **fresh** world whose component types are already registered.
///
/// Two passes, deliberately. Everything structural is validated before anything is
/// applied, so a corrupt file leaves the world exactly as it was rather than half
/// populated. The exception is an allocation failure during the second pass, which leaves
/// a partly populated world the caller should discard; there is no way to reserve the
/// whole of it up front and no honest way to pretend otherwise.
pub fn read(
    world: *World,
    gpa: Allocator,
    bytes: []const u8,
    limits: data.Limits,
) ReadError!Summary {
    if (world.entities.capacity() != 0) return error.WorldNotEmpty;
    if (bytes.len < header_size) return error.NotASave;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.NotASave;
    if (std.mem.readInt(u32, bytes[4..8], .little) != format_version) {
        return error.SaveUnsupportedVersion;
    }
    if (std.mem.readInt(u32, bytes[8..12], .little) != 0) return error.SaveUnsupportedFlags;

    const type_count = std.mem.readInt(u32, bytes[12..16], .little);
    const slot_count = std.mem.readInt(u32, bytes[16..20], .little);
    const free_count = std.mem.readInt(u32, bytes[20..24], .little);

    const types_section = sectionAt(bytes, 24) orelse return error.SaveCorrupt;
    const slots_section = sectionAt(bytes, 32) orelse return error.SaveCorrupt;
    const free_section = sectionAt(bytes, 40) orelse return error.SaveCorrupt;
    const owners_section = sectionAt(bytes, 48) orelse return error.SaveCorrupt;
    const fields_section = sectionAt(bytes, 56) orelse return error.SaveCorrupt;
    const strings_section = sectionAt(bytes, 64) orelse return error.SaveCorrupt;

    if (!std.unicode.utf8ValidateSlice(strings_section)) return error.SaveCorrupt;

    // Counts are believed only once the bytes to hold them have been found.
    if (@as(u64, type_count) * type_entry_size > types_section.len) return error.SaveCorrupt;
    if (@as(u64, slot_count) * slot_entry_size != slots_section.len) return error.SaveCorrupt;
    if (@as(u64, free_count) * 4 != free_section.len) return error.SaveCorrupt;
    if (free_count > slot_count) return error.SaveCorrupt;
    if (slot_count > world.limits.max_entities) return error.SaveCorrupt;
    if (type_count > world.limits.max_component_types) return error.SaveCorrupt;

    var arena: core.Arena = .init(gpa);
    defer arena.deinit();

    // --- pass one: the entity pool, as the file describes it ---------------
    const pool = try arena.allocator().alloc(core.HandlePool(Entities, void).Snapshot, slot_count);
    for (pool, 0..) |*s, i| {
        const e = slots_section[i * slot_entry_size ..][0..slot_entry_size];
        const generation = std.mem.readInt(u32, e[0..4], .little);
        const occupied = std.mem.readInt(u32, e[4..8], .little);
        if (generation == 0) return error.SaveCorrupt;
        if (occupied > 1) return error.SaveCorrupt;
        s.* = .{ .generation = generation, .value = if (occupied == 1) {} else null };
    }
    const free_list = try arena.allocator().alloc(u32, free_count);
    for (free_list, 0..) |*index, i| {
        index.* = std.mem.readInt(u32, free_section[i * 4 ..][0..4], .little);
    }

    // --- pass one: the component types, and every owner they name ----------
    const blocks: data.Blocks = .{
        .fields = fields_section,
        .strings = strings_section,
        .max_list_elements = limits.max_list_elements,
    };
    const decls = types_section[type_count * type_entry_size ..];

    const plans = try arena.allocator().alloc(Plan, type_count);
    // Two entries for one component type would try to give an entity the same component
    // twice. Caught here rather than by the second `addComponent`, so it costs nothing
    // that has already been applied.
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var summary: Summary = .{};
    for (plans, 0..) |*plan, i| {
        const e = types_section[i * type_entry_size ..][0..type_entry_size];
        if (std.mem.readInt(u32, e[36..40], .little) != 0) return error.SaveCorrupt;
        const id = std.mem.readInt(u64, e[0..8], .little);
        if ((try seen.fetchPut(arena.allocator(), id, {})) != null) return error.SaveCorrupt;
        plan.* = try planFor(world, &arena, e, decls, strings_section, owners_section, blocks, limits, pool);
        if (plan.fields == null) summary.skipped_types += 1;
    }

    // --- pass two: apply ---------------------------------------------------
    world.entities.restore(gpa, pool, free_list) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSnapshot => return error.SaveCorrupt,
    };
    summary.entities = world.entities.count();

    for (plans) |plan| {
        const fields = plan.fields orelse continue;
        var dense: u32 = 0;
        while (dense < plan.count) : (dense += 1) {
            const owner = plan.ownerAt(owners_section, dense);
            // Both were checked in pass one, which is why neither can fail here.
            const view = blocks.blockInArray(plan.blocks_offset, fields, dense).?;
            const bytes_out = world.addComponent(owner, plan.type, null) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Every one of these was ruled out in pass one, and reaching one means the
                // world changed underneath the load.
                else => return error.SaveCorrupt,
            };
            plan.deserialize(plan.ctx, view, bytes_out.ptr) catch {
                return error.SaveCorrupt;
            };
            summary.components += 1;
        }
    }
    return summary;
}

/// One component type's entry, resolved against this build. `fields` is null for a type
/// that is being skipped.
const Plan = struct {
    type: component.ComponentType = .none,
    ctx: ?*anyopaque = null,
    deserialize: component.DeserializeFn = undefined,
    /// The schema **the file was written with**, which is what the blocks are laid out
    /// against — not this build's, which may have appended fields since.
    fields: ?[]const Field = null,
    count: u32 = 0,
    owners_offset: u32 = 0,
    blocks_offset: u32 = 0,

    fn ownerAt(self: Plan, owners: []const u8, dense: u32) Entity {
        return Entity.fromBits(std.mem.readInt(u64, owners[self.owners_offset + dense * 8 ..][0..8], .little));
    }
};

fn planFor(
    world: *World,
    arena: *core.Arena,
    entry: *const [type_entry_size]u8,
    decls: []const u8,
    strings: []const u8,
    owners: []const u8,
    blocks: data.Blocks,
    limits: data.Limits,
    pool: []const core.HandlePool(Entities, void).Snapshot,
) ReadError!Plan {
    const schema_id: data.SchemaId = .{ .hash = std.mem.readInt(u64, entry[0..8], .little) };
    const version = std.mem.readInt(u32, entry[8..12], .little);
    const name = stringAt(strings, entry[12..20]) orelse return error.SaveCorrupt;
    const decl_offset = std.mem.readInt(u32, entry[20..24], .little);
    const count = std.mem.readInt(u32, entry[24..28], .little);
    const owners_offset = std.mem.readInt(u32, entry[28..32], .little);
    const blocks_offset = std.mem.readInt(u32, entry[32..36], .little);

    if (decl_offset > decls.len) return error.SaveCorrupt;
    if (count > world.limits.max_entities) return error.SaveCorrupt;
    if (@as(u64, owners_offset) + @as(u64, count) * 8 > owners.len) return error.SaveCorrupt;

    // The schema the file carries, decoded before anything is read against it. Bounded by
    // the same limits a package's is, and for the same reason.
    var decoder: data.SchemaDecoder = .{
        .bytes = decls,
        .pos = decl_offset,
        .arena = arena.allocator(),
        .strings = strings,
        .limits = limits,
    };
    const fields = decoder.readFields() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SaveCorrupt,
    };

    // Every block has to be inside the fields section whether or not this build wants the
    // type, because a file whose offsets are wrong is corrupt rather than skippable.
    var dense: u32 = 0;
    while (dense < count) : (dense += 1) {
        if (blocks.blockInArray(blocks_offset, fields, dense) == null) return error.SaveCorrupt;
        const bits = std.mem.readInt(u64, owners[owners_offset + dense * 8 ..][0..8], .little);
        const owner = Entity.fromBits(bits);
        // Live in the pool the same file just described — checked here rather than trusted
        // to `addComponent`, so the check happens before anything has been applied.
        if (owner.index >= pool.len) return error.SaveCorrupt;
        const slot = pool[owner.index];
        if (slot.value == null or slot.generation != owner.generation) return error.SaveCorrupt;
    }

    const handle = world.findComponent(schema_id) orelse {
        log.debug("save carries component type '{s}' v{d}, which is not registered; skipping {d}", .{ name, version, count });
        return .{};
    };
    const reg = world.componentInfo(handle).?;
    const deserialize = reg.deserialize orelse {
        log.warn("component type '{s}' cannot be built from data; skipping {d} from the save", .{ name, count });
        return .{};
    };
    // The blocks are read by position, so a file that ordered the fields differently would
    // read one field's bytes into another and report success. Same rule as a package's
    // schema agreement, and the same refusal.
    const registered = world.schemas.get(reg.schema) orelse return .{};
    if (!prefixAgrees(fields, registered.fields)) {
        log.warn("component type '{s}' in the save disagrees with the registered schema; skipping {d}", .{ name, count });
        return .{};
    }

    return .{
        .type = handle,
        .ctx = reg.ctx,
        .deserialize = deserialize,
        .fields = fields,
        .count = count,
        .owners_offset = owners_offset,
        .blocks_offset = blocks_offset,
    };
}

/// Whether two field lists agree everywhere they overlap.
///
/// A schema may only append, so the shorter one being a prefix of the longer is exactly
/// what compatibility means (`content-schemas.md` §3).
fn prefixAgrees(a: []const Field, b: []const Field) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        if (!x.eql(y)) return false;
    }
    return true;
}

fn sectionAt(bytes: []const u8, header_offset: usize) ?[]const u8 {
    const offset = std.mem.readInt(u32, bytes[header_offset..][0..4], .little);
    const len = std.mem.readInt(u32, bytes[header_offset + 4 ..][0..4], .little);
    if (offset % section_align != 0) return null;
    if (@as(u64, offset) + len > bytes.len) return null;
    return bytes[offset..][0..len];
}

fn stringAt(strings: []const u8, ref: *const [8]u8) ?[]const u8 {
    const offset = std.mem.readInt(u32, ref[0..4], .little);
    const len = std.mem.readInt(u32, ref[4..8], .little);
    const end = @as(u64, offset) + len;
    if (end > strings.len) return null;
    return strings[offset..][0..len];
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;
const derive = @import("derive.zig");

const Pos = struct {
    pub const component = "test:pos";
    x: f32 = 0,
    y: f32 = 0,
};

const Health = struct {
    pub const component = "test:health";
    hp: i32 = 100,
    alive: bool = true,
};

const Link = struct {
    pub const component = "test:link";
    /// The field that only works because identity survives a reload.
    other: Entity = .none,
    texture: core.ContentId = .none,
};

const Player = struct {
    pub const component = "test:player";
};

/// A world with the four types above registered, and nothing else.
const Fixture = struct {
    gpa: Allocator,
    registry: data.Registry,
    world: World,
    pos: component.ComponentType = .none,
    health: component.ComponentType = .none,
    link: component.ComponentType = .none,
    player: component.ComponentType = .none,

    fn init(gpa: Allocator) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{ .gpa = gpa, .registry = .init(gpa, .default), .world = undefined };
        self.world = .init(gpa, &self.registry, .default);
        self.pos = try self.world.registerComponent(derive.componentType(Pos));
        self.health = try self.world.registerComponent(derive.componentType(Health));
        self.link = try self.world.registerComponent(derive.componentType(Link));
        self.player = try self.world.registerComponent(derive.componentType(Player));
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.world.deinit();
        self.registry.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn add(self: *Fixture, e: Entity, t: component.ComponentType, value: anytype) !void {
        const bytes = std.mem.asBytes(&value);
        _ = try self.world.addComponent(e, t, bytes[0..@sizeOf(@TypeOf(value))]);
    }

    fn get(self: *Fixture, comptime T: type, e: Entity, t: component.ComponentType) ?T {
        const bytes = self.world.getComponent(e, t) orelse return null;
        var out: T = undefined;
        @memcpy(std.mem.asBytes(&out)[0..@sizeOf(T)], bytes);
        return out;
    }
};

/// Builds the same world every time: four entities, one of them destroyed so the pool has
/// a hole and a reused slot, and a component that refers to another entity.
fn populate(f: *Fixture) !struct { a: Entity, b: Entity, c: Entity, gone: Entity } {
    const a = try f.world.create();
    const gone = try f.world.create();
    const b = try f.world.create();

    try f.add(a, f.pos, Pos{ .x = 1.5, .y = -2.5 });
    try f.add(a, f.health, Health{ .hp = 42, .alive = false });
    try f.add(gone, f.pos, Pos{ .x = 9, .y = 9 });
    try f.add(b, f.pos, Pos{ .x = 3, .y = 4 });
    try f.add(b, f.link, Link{ .other = a, .texture = try data.id.contentId("test:tex.stone") });
    try f.add(b, f.player, Player{});

    // Destroyed after its components were added, so the dense arrays have had a hole
    // swapped out of them and the pool has a free slot with an advanced generation.
    try testing.expect(f.world.destroy(gone));
    const c = try f.world.create(); // reuses `gone`'s slot at a new generation
    try f.add(c, f.pos, Pos{ .x = -1, .y = -1 });

    return .{ .a = a, .b = b, .c = c, .gone = gone };
}

fn saveOf(f: *Fixture) !std.ArrayList(u8) {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(f.gpa);
    try f.world.save(&bytes);
    return bytes;
}

test "a world survives a round trip through a save" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit();
    const e = try populate(f);

    var bytes = try saveOf(f);
    defer bytes.deinit(gpa);

    const g = try Fixture.init(gpa);
    defer g.deinit();
    const summary = try g.world.load(bytes.items, .default);

    try testing.expectEqual(@as(u32, 3), summary.entities);
    try testing.expectEqual(@as(u32, 6), summary.components);
    try testing.expectEqual(@as(u32, 0), summary.skipped_types);

    // The same handles, not merely the same number of entities.
    try testing.expect(g.world.contains(e.a));
    try testing.expect(g.world.contains(e.b));
    try testing.expect(g.world.contains(e.c));
    // And the destroyed one is still destroyed, at the generation it died at.
    try testing.expect(!g.world.contains(e.gone));

    try testing.expectEqual(@as(f32, 1.5), g.get(Pos, e.a, g.pos).?.x);
    try testing.expectEqual(@as(f32, -2.5), g.get(Pos, e.a, g.pos).?.y);
    try testing.expectEqual(@as(i32, 42), g.get(Health, e.a, g.health).?.hp);
    try testing.expectEqual(false, g.get(Health, e.a, g.health).?.alive);
    try testing.expectEqual(@as(f32, 3), g.get(Pos, e.b, g.pos).?.x);
    try testing.expect(g.world.hasComponent(e.b, g.player));
    try testing.expect(!g.world.hasComponent(e.a, g.player));
    try testing.expect(g.get(Health, e.b, g.health) == null);
}

test "an entity reference inside a component still points at the same entity" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit();
    const e = try populate(f);

    var bytes = try saveOf(f);
    defer bytes.deinit(gpa);

    const g = try Fixture.init(gpa);
    defer g.deinit();
    _ = try g.world.load(bytes.items, .default);

    // This is the whole reason the pool's exact state is in the file. `other` is a raw
    // 64-bit handle written by a serializer that has no idea it is one — no remapping
    // pass, and `scene` never has to know which fields are entity references.
    const link = g.get(Link, e.b, g.link).?;
    try testing.expect(link.other.eql(e.a));
    try testing.expect(g.world.contains(link.other));
    try testing.expectEqual(@as(f32, 1.5), g.get(Pos, link.other, g.pos).?.x);
    try testing.expect(link.texture.eql(try data.id.contentId("test:tex.stone")));
}

test "a reloaded world hands out the handles the original would have" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit();
    _ = try populate(f);

    var bytes = try saveOf(f);
    defer bytes.deinit(gpa);

    const g = try Fixture.init(gpa);
    defer g.deinit();
    _ = try g.world.load(bytes.items, .default);

    // Not just the same count: the next entity each world creates is the same handle, and
    // the one after it too. Anything less and a save-reload changes what a later handle
    // means.
    for (0..3) |_| {
        const original = try f.world.create();
        const reloaded = try g.world.create();
        try testing.expect(original.eql(reloaded));
    }
}

test "iteration order survives the round trip" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit();
    _ = try populate(f);

    var bytes = try saveOf(f);
    defer bytes.deinit(gpa);

    const g = try Fixture.init(gpa);
    defer g.deinit();
    _ = try g.world.load(bytes.items, .default);

    // Dense order is written and restored in dense order, so a query visits the same
    // entities in the same sequence — including the swap-removal shuffle that destroying
    // an entity left behind. §5's rule is only worth anything if a reload keeps it.
    var before = f.world.query(&.{f.pos});
    var after = g.world.query(&.{g.pos});
    while (before.next()) |expected| {
        const actual = after.next() orelse return error.TestUnexpectedResult;
        try testing.expect(expected.eql(actual));
    }
    try testing.expect(after.next() == null);
}

test "two saves of one world are byte-identical" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit();
    _ = try populate(f);

    var first = try saveOf(f);
    defer first.deinit(gpa);
    var second = try saveOf(f);
    defer second.deinit(gpa);
    try testing.expectEqualSlices(u8, first.items, second.items);
}

test "a component type the build does not know is skipped, not fatal" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit();
    const e = try populate(f);

    var bytes = try saveOf(f);
    defer bytes.deinit(gpa);

    // A build without the mod that defined `test:link` and `test:player`.
    var registry: data.Registry = .init(gpa, .default);
    defer registry.deinit(gpa);
    var world: World = .init(gpa, &registry, .default);
    defer world.deinit();
    const pos = try world.registerComponent(derive.componentType(Pos));

    const summary = try world.load(bytes.items, .default);
    try testing.expectEqual(@as(u32, 3), summary.entities);
    try testing.expectEqual(@as(u32, 3), summary.skipped_types); // health, link, player
    try testing.expectEqual(@as(u32, 3), summary.components);

    // The entities are all there, minus the components this build cannot name.
    try testing.expect(world.contains(e.a));
    try testing.expect(world.getComponent(e.a, pos) != null);
}

test "a type whose schema disagrees with the save is skipped" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit();
    _ = try populate(f);

    var bytes = try saveOf(f);
    defer bytes.deinit(gpa);

    // Same content ID, fields in the other order. Reading by position would put `y` into
    // `x` and report success, which is worse than not loading it at all.
    const Swapped = struct {
        pub const component = "test:pos";
        y: f32 = 0,
        x: f32 = 0,
    };
    var registry: data.Registry = .init(gpa, .default);
    defer registry.deinit(gpa);
    var world: World = .init(gpa, &registry, .default);
    defer world.deinit();
    const pos = try world.registerComponent(derive.componentType(Swapped));

    const summary = try world.load(bytes.items, .default);
    try testing.expectEqual(@as(u32, 3), summary.entities);
    try testing.expectEqual(@as(u32, 0), world.componentCount(pos));
    try testing.expectEqual(@as(u32, 4), summary.skipped_types);
}

test "a type that cannot be serialized is left out of the file" {
    const gpa = testing.allocator;
    var registry: data.Registry = .init(gpa, .default);
    defer registry.deinit(gpa);
    var world: World = .init(gpa, &registry, .default);
    defer world.deinit();

    // A registration with no codec at all: something purely internal, or a derived cache.
    var info = derive.componentType(Pos);
    info.serialize = null;
    info.deserialize = null;
    const pos = try world.registerComponent(info);

    const e = try world.create();
    _ = try world.addComponent(e, pos, null);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try world.save(&bytes);

    const f = try Fixture.init(gpa);
    defer f.deinit();
    const summary = try f.world.load(bytes.items, .default);
    // The entity is saved; its unsaveable component is not, and its absence is not an
    // error on either side.
    try testing.expectEqual(@as(u32, 1), summary.entities);
    try testing.expectEqual(@as(u32, 0), summary.components);
    try testing.expectEqual(@as(u32, 0), summary.skipped_types);
    try testing.expect(!f.world.hasComponent(e, f.pos));
}

test "loading into a world that already has entities is refused" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit();
    _ = try populate(f);

    var bytes = try saveOf(f);
    defer bytes.deinit(gpa);

    const g = try Fixture.init(gpa);
    defer g.deinit();
    _ = try g.world.create();
    try testing.expectError(error.WorldNotEmpty, g.world.load(bytes.items, .default));
}

test "a save is recognised by its own magic and version" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit();
    _ = try populate(f);

    var bytes = try saveOf(f);
    defer bytes.deinit(gpa);
    try testing.expectEqual(format_version, versionOf(bytes.items).?);
    try testing.expect(versionOf("nope") == null);

    const g = try Fixture.init(gpa);
    defer g.deinit();
    try testing.expectError(error.NotASave, g.world.load("not a save at all", .default));
    try testing.expectError(error.NotASave, g.world.load(&.{}, .default));

    // A save from a later Foundry says so, rather than saying it is not a save.
    var future = try bytes.clone(gpa);
    defer future.deinit(gpa);
    std.mem.writeInt(u32, future.items[4..8], format_version + 1, .little);
    try testing.expectError(error.SaveUnsupportedVersion, g.world.load(future.items, .default));

    // And a flag bit this build does not know changes how bytes are read, so it is
    // refused rather than ignored.
    var flagged = try bytes.clone(gpa);
    defer flagged.deinit(gpa);
    std.mem.writeInt(u32, flagged.items[8..12], 1, .little);
    try testing.expectError(error.SaveUnsupportedFlags, g.world.load(flagged.items, .default));
}

test "one changed byte anywhere is refused or loads cleanly, never anything else" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit();
    _ = try populate(f);

    var bytes = try saveOf(f);
    defer bytes.deinit(gpa);

    // The `.fpk` reader's test, applied to the same discipline: every single-byte change,
    // every bit. Nothing here may read out of bounds, allocate wildly or panic — and a
    // load that succeeds must produce a world that is still internally consistent.
    for (0..bytes.items.len) |i| {
        for ([_]u8{ 0x00, 0x01, 0x7f, 0x80, 0xff }) |patch| {
            const original = bytes.items[i];
            if (original == patch) continue;
            bytes.items[i] = patch;
            defer bytes.items[i] = original;

            const g = try Fixture.init(gpa);
            defer g.deinit();
            const summary = g.world.load(bytes.items, .default) catch continue;
            try testing.expectEqual(summary.entities, g.world.entityCount());
        }
    }
}

test "an empty world round-trips" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit();

    var bytes = try saveOf(f);
    defer bytes.deinit(gpa);

    const g = try Fixture.init(gpa);
    defer g.deinit();
    const summary = try g.world.load(bytes.items, .default);
    try testing.expectEqual(@as(u32, 0), summary.entities);
    try testing.expectEqual(@as(u32, 0), summary.components);
    // Four registered types, all of them empty, all of them still carried — so a save of
    // an empty world still says what shape its components had.
    try testing.expectEqual(@as(u32, 0), summary.skipped_types);
}

test "clear leaves the world usable and the old handles stale" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit();
    const e = try populate(f);

    f.world.clear();
    try testing.expectEqual(@as(u32, 0), f.world.entityCount());
    try testing.expectEqual(@as(u32, 0), f.world.componentCount(f.pos));
    try testing.expect(!f.world.contains(e.a));

    // And the slots come back at advanced generations, so a handle held across a clear
    // does not come back looking live.
    const fresh = try f.world.create();
    try testing.expect(!fresh.eql(e.a));
    try testing.expect(f.world.contains(fresh));
}
