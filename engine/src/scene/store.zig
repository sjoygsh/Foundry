//! Type-erased component storage: a sparse set with dense arrays.
//!
//! One store per registered component type, holding bytes it does not understand. The
//! shape is ADR-0010's — "the simplest thing that works ... behind an interface that
//! allows a later upgrade to archetype-based storage without touching gameplay code":
//!
//! ```
//! sparse:  entity index -> dense position, or `absent`
//! owners:  dense; which entity each element belongs to
//! bytes:   dense; `stride` bytes per element
//! ```
//!
//! **`owners` is what makes a stale handle safe.** The sparse entry alone would answer
//! for a slot that has since been reused, so every lookup compares the *whole* handle —
//! index and generation — against the owner recorded beside the data. Failing that
//! comparison is a normal condition, not a bug (I1).
//!
//! Nothing outside this file may learn any of the three arrays exist. Queries return
//! entities and component bytes, because archetype storage has none of these arrays and a
//! caller that has learned the layout is a caller that blocks the upgrade.
//!
//! Design: `docs/design/entity-storage.md` §4.

const std = @import("std");
const core = @import("core");

const component = @import("component.zig");
const entity_mod = @import("entity.zig");

const Allocator = std.mem.Allocator;
const Entity = entity_mod.Entity;
const Registration = component.Registration;

/// No component for this entity. `maxInt` rather than 0, so a zeroed sparse array is
/// empty rather than pointing every entity at dense element 0.
pub const absent: u32 = std.math.maxInt(u32);

/// Dense bytes, aligned to a component type's alignment.
///
/// The alignment is a runtime value, which `Allocator.alloc` cannot express, so the block
/// over-allocates by `alignment - 1` and keeps its own aligned base. That wastes at most
/// fifteen bytes per store for any component anyone has yet wanted, and it stays inside
/// the allocator's public interface — `rawAlloc` takes a runtime alignment but says in its
/// own doc comment that it is not for callers.
const Block = struct {
    /// What was allocated, and what is freed. Empty when nothing is allocated.
    raw: []u8 = &.{},
    /// The aligned base. When `cap` is 0 this is a non-null aligned address that is never
    /// dereferenced, so `ptr[0..0]` is a valid empty slice.
    ptr: [*]u8,
    /// Usable bytes from `ptr`.
    cap: usize = 0,

    fn init(alignment: u32) Block {
        return .{ .ptr = @ptrFromInt(alignment) };
    }

    fn deinit(self: *Block, gpa: Allocator, alignment: u32) void {
        gpa.free(self.raw);
        self.* = .init(alignment);
    }

    /// Grows to hold at least `wanted` bytes, preserving the first `keep` of them.
    fn ensure(self: *Block, gpa: Allocator, alignment: u32, wanted: usize, keep: usize) Allocator.Error!void {
        if (wanted <= self.cap) return;

        var next = if (self.cap == 0) wanted else self.cap;
        while (next < wanted) next = next * 2;

        const raw = try gpa.alloc(u8, next + alignment - 1);
        const base = @intFromPtr(raw.ptr);
        const aligned = std.mem.alignForward(usize, base, alignment);
        const ptr: [*]u8 = @ptrFromInt(aligned);

        if (keep != 0) @memcpy(ptr[0..keep], self.ptr[0..keep]);
        gpa.free(self.raw);

        self.raw = raw;
        self.ptr = ptr;
        self.cap = next;
    }
};

/// The storage for one component type.
pub const ComponentStore = struct {
    size: u32,
    stride: u32,
    alignment: u32,

    ctx: ?*anyopaque,
    construct: ?*const fn (ctx: ?*anyopaque, out: [*]u8) void,
    destruct: ?*const fn (ctx: ?*anyopaque, component: [*]u8) void,

    sparse: std.ArrayList(u32) = .empty,
    owners: std.ArrayList(Entity) = .empty,
    bytes: Block,

    pub fn init(reg: *const Registration) ComponentStore {
        return .{
            .size = reg.size,
            .stride = reg.stride,
            .alignment = reg.alignment,
            .ctx = reg.ctx,
            .construct = reg.construct,
            .destruct = reg.destruct,
            .bytes = .init(reg.alignment),
        };
    }

    /// Runs `destruct` over every live component before releasing anything, because a
    /// component that owns memory has to be told so while its bytes still exist.
    pub fn deinit(self: *ComponentStore, gpa: Allocator) void {
        if (self.destruct) |destruct| {
            for (0..self.owners.items.len) |i| destruct(self.ctx, self.at(@intCast(i)).ptr);
        }
        self.sparse.deinit(gpa);
        self.owners.deinit(gpa);
        self.bytes.deinit(gpa, self.alignment);
        self.* = undefined;
    }

    pub fn count(self: *const ComponentStore) u32 {
        return @intCast(self.owners.items.len);
    }

    /// The dense position of an entity's component, or null.
    ///
    /// Both halves of the handle are compared. A sparse entry survives its entity, so the
    /// index alone would happily answer for whoever reused the slot.
    pub fn denseIndex(self: *const ComponentStore, entity: Entity) ?u32 {
        if (entity.isNone()) return null;
        if (entity.index >= self.sparse.items.len) return null;
        const dense = self.sparse.items[entity.index];
        if (dense == absent) return null;
        if (!self.owners.items[dense].eql(entity)) return null;
        return dense;
    }

    pub fn has(self: *const ComponentStore, entity: Entity) bool {
        return self.denseIndex(entity) != null;
    }

    /// The component's bytes, or null if the entity does not have one.
    ///
    /// **A borrow, valid until the next mutation of this store.** Adding a component may
    /// move the dense array; removing one moves the last element into the hole. Hold the
    /// entity, not the pointer — the same rule `core.HandlePool.get` states, and the
    /// reason the query iterators guard against structural change (§5).
    pub fn get(self: *const ComponentStore, entity: Entity) ?[]u8 {
        return self.at(self.denseIndex(entity) orelse return null);
    }

    /// The bytes at a dense position. For a marker this is a valid empty slice.
    pub fn at(self: *const ComponentStore, dense: u32) []u8 {
        const offset = @as(usize, dense) * self.stride;
        return self.bytes.ptr[offset..][0..self.size];
    }

    pub fn ownerAt(self: *const ComponentStore, dense: u32) Entity {
        return self.owners.items[dense];
    }

    /// Adds a component to an entity and returns its bytes.
    ///
    /// `initial` is either exactly `size` bytes to copy, or null — in which case
    /// `construct` runs if the type has one, and the bytes are zeroed if it does not.
    /// Zeroed is the documented meaning of "no constructor", so it is done here rather
    /// than left as whatever the allocator returned.
    ///
    /// The caller has already established that the entity is live and does not have this
    /// component; this is the storage, not the policy.
    pub fn add(
        self: *ComponentStore,
        gpa: Allocator,
        entity: Entity,
        initial: ?[]const u8,
    ) Allocator.Error![]u8 {
        std.debug.assert(self.denseIndex(entity) == null);
        if (initial) |src| std.debug.assert(src.len == self.size);

        // Everything that can fail happens before anything is written, so a failed add
        // leaves the store exactly as it was.
        if (entity.index >= self.sparse.items.len) {
            const grown = @as(usize, entity.index) + 1;
            try self.sparse.ensureTotalCapacity(gpa, grown);
            while (self.sparse.items.len < grown) self.sparse.appendAssumeCapacity(absent);
        }
        try self.owners.ensureUnusedCapacity(gpa, 1);
        const dense: u32 = @intCast(self.owners.items.len);
        try self.bytes.ensure(gpa, self.alignment, (@as(usize, dense) + 1) * self.stride, @as(usize, dense) * self.stride);

        self.owners.appendAssumeCapacity(entity);
        self.sparse.items[entity.index] = dense;

        const slot = self.at(dense);
        if (initial) |src| {
            @memcpy(slot, src);
        } else if (self.construct) |construct| {
            construct(self.ctx, slot.ptr);
        } else {
            @memset(slot, 0);
        }
        return slot;
    }

    /// Removes an entity's component. False if it did not have one, which is not an error.
    ///
    /// Swap-removal: the last dense element moves into the hole. That is what makes dense
    /// order depend on removal history — deterministic, documented, and the reason §5 says
    /// a system whose *results* depend on order must sort by entity rather than rely on it.
    pub fn remove(self: *ComponentStore, entity: Entity) bool {
        const dense = self.denseIndex(entity) orelse return false;

        if (self.destruct) |destruct| destruct(self.ctx, self.at(dense).ptr);

        const last: u32 = @intCast(self.owners.items.len - 1);
        if (dense != last) {
            const moved = self.owners.items[last];
            self.owners.items[dense] = moved;
            @memcpy(self.at(dense), self.at(last));
            self.sparse.items[moved.index] = dense;
        }
        _ = self.owners.pop();
        self.sparse.items[entity.index] = absent;
        return true;
    }
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

const Pair = extern struct { a: u32, b: u32 };

fn pairRegistration() Registration {
    return .{
        .id = .none,
        .schema = .none,
        .name = "test:pair",
        .size = @sizeOf(Pair),
        .alignment = @alignOf(Pair),
        .stride = component.strideFor(@sizeOf(Pair), @alignOf(Pair)),
        .ctx = null,
        .construct = null,
        .destruct = null,
        .deserialize = null,
        .serialize = null,
    };
}

fn pairOf(bytes: []u8) *Pair {
    return @ptrCast(@alignCast(bytes.ptr));
}

fn e(index: u32, generation: u32) Entity {
    return .{ .index = index, .generation = generation };
}

test "a component is added, found and removed" {
    const gpa = testing.allocator;
    var store: ComponentStore = .init(&pairRegistration());
    defer store.deinit(gpa);

    const one = e(0, 1);
    const two = e(1, 1);

    var value: Pair = .{ .a = 7, .b = 8 };
    _ = try store.add(gpa, one, std.mem.asBytes(&value));
    _ = try store.add(gpa, two, null);

    try testing.expectEqual(@as(u32, 2), store.count());
    try testing.expect(store.has(one));
    try testing.expectEqual(@as(u32, 7), pairOf(store.get(one).?).a);
    // No constructor means zeroed, which is the documented meaning rather than whatever
    // the allocator last had there.
    try testing.expectEqual(@as(u32, 0), pairOf(store.get(two).?).a);

    try testing.expect(store.remove(one));
    try testing.expect(!store.has(one));
    try testing.expect(store.get(one) == null);
    try testing.expect(store.has(two));
    try testing.expectEqual(@as(u32, 1), store.count());

    // Removing what is not there is false, not a crash.
    try testing.expect(!store.remove(one));
}

test "a stale entity does not inherit the component of the slot it reused" {
    const gpa = testing.allocator;
    var store: ComponentStore = .init(&pairRegistration());
    defer store.deinit(gpa);

    const old = e(3, 1);
    var value: Pair = .{ .a = 1, .b = 1 };
    _ = try store.add(gpa, old, std.mem.asBytes(&value));

    // The slot is reused by a later entity, which is given its own component.
    try testing.expect(store.remove(old));
    const new = e(3, 2);
    value = .{ .a = 2, .b = 2 };
    _ = try store.add(gpa, new, std.mem.asBytes(&value));

    // The sparse entry answers for index 3 either way; only the owner check separates them.
    try testing.expect(!store.has(old));
    try testing.expect(store.get(old) == null);
    try testing.expectEqual(@as(u32, 2), pairOf(store.get(new).?).a);
    try testing.expect(store.get(Entity.none) == null);
}

test "swap-removal moves the last element and repairs its sparse entry" {
    const gpa = testing.allocator;
    var store: ComponentStore = .init(&pairRegistration());
    defer store.deinit(gpa);

    for (0..4) |i| {
        var value: Pair = .{ .a = @intCast(i), .b = 0 };
        _ = try store.add(gpa, e(@intCast(i), 1), std.mem.asBytes(&value));
    }

    // Remove the first: the last (3) moves into position 0, and must still be findable.
    try testing.expect(store.remove(e(0, 1)));
    try testing.expectEqual(@as(u32, 3), store.count());
    try testing.expectEqual(@as(u32, 3), pairOf(store.get(e(3, 1)).?).a);
    try testing.expectEqual(@as(u32, 3), pairOf(store.at(0)).a);
    try testing.expect(store.ownerAt(0).eql(e(3, 1)));

    // Everything else is intact and still says what it said.
    try testing.expectEqual(@as(u32, 1), pairOf(store.get(e(1, 1)).?).a);
    try testing.expectEqual(@as(u32, 2), pairOf(store.get(e(2, 1)).?).a);
}

test "dense order is insertion order until a removal reorders it" {
    const gpa = testing.allocator;
    var store: ComponentStore = .init(&pairRegistration());
    defer store.deinit(gpa);

    for (0..3) |i| {
        var value: Pair = .{ .a = @intCast(i), .b = 0 };
        _ = try store.add(gpa, e(@intCast(i), 1), std.mem.asBytes(&value));
    }
    try testing.expectEqual(@as(u32, 0), pairOf(store.at(0)).a);
    try testing.expectEqual(@as(u32, 1), pairOf(store.at(1)).a);
    try testing.expectEqual(@as(u32, 2), pairOf(store.at(2)).a);

    // §5's caveat, made visible: removing the middle element puts the last one there. The
    // order is reproducible, and it is not entity order.
    try testing.expect(store.remove(e(1, 1)));
    try testing.expectEqual(@as(u32, 0), pairOf(store.at(0)).a);
    try testing.expectEqual(@as(u32, 2), pairOf(store.at(1)).a);
}

test "a sparse entity index grows the array without disturbing what is there" {
    const gpa = testing.allocator;
    var store: ComponentStore = .init(&pairRegistration());
    defer store.deinit(gpa);

    var value: Pair = .{ .a = 1, .b = 0 };
    _ = try store.add(gpa, e(0, 1), std.mem.asBytes(&value));

    value = .{ .a = 2, .b = 0 };
    _ = try store.add(gpa, e(1000, 1), std.mem.asBytes(&value));

    try testing.expectEqual(@as(u32, 1), pairOf(store.get(e(0, 1)).?).a);
    try testing.expectEqual(@as(u32, 2), pairOf(store.get(e(1000, 1)).?).a);
    // Everything between is empty rather than pointing at dense element 0.
    try testing.expect(!store.has(e(500, 1)));
}

test "the dense array stays aligned as it grows" {
    const gpa = testing.allocator;
    const Wide = extern struct { v: u64 align(16) };
    var store: ComponentStore = .init(&.{
        .id = .none,
        .schema = .none,
        .name = "test:wide",
        .size = @sizeOf(Wide),
        .alignment = 16,
        .stride = component.strideFor(@sizeOf(Wide), 16),
        .ctx = null,
        .construct = null,
        .destruct = null,
        .deserialize = null,
        .serialize = null,
    });
    defer store.deinit(gpa);

    // Enough additions to force several reallocations of the block.
    for (0..64) |i| {
        var value: Wide = .{ .v = i };
        _ = try store.add(gpa, e(@intCast(i), 1), std.mem.asBytes(&value));
        const bytes = store.get(e(@intCast(i), 1)).?;
        try testing.expectEqual(@as(usize, 0), @intFromPtr(bytes.ptr) % 16);
    }

    // And the values survived every move.
    for (0..64) |i| {
        const bytes = store.get(e(@intCast(i), 1)).?;
        const wide: *Wide = @ptrCast(@alignCast(bytes.ptr));
        try testing.expectEqual(i, wide.v);
    }
}

test "a marker component stores presence and no bytes" {
    const gpa = testing.allocator;
    var store: ComponentStore = .init(&.{
        .id = .none,
        .schema = .none,
        .name = "test:marker",
        .size = 0,
        .alignment = 1,
        .stride = 0,
        .ctx = null,
        .construct = null,
        .destruct = null,
        .deserialize = null,
        .serialize = null,
    });
    defer store.deinit(gpa);

    const one = e(0, 1);
    const two = e(1, 1);
    const bytes = try store.add(gpa, one, null);
    try testing.expectEqual(@as(usize, 0), bytes.len);
    _ = try store.add(gpa, two, null);

    try testing.expect(store.has(one));
    try testing.expect(store.has(two));
    try testing.expectEqual(@as(u32, 2), store.count());

    // Swap-removal still has to move the owner, even with nothing to copy.
    try testing.expect(store.remove(one));
    try testing.expect(!store.has(one));
    try testing.expect(store.has(two));
    try testing.expect(store.ownerAt(0).eql(two));
}

/// A component type that owns something, to prove `construct` and `destruct` run.
const Counted = struct {
    var constructed: u32 = 0;
    var destructed: u32 = 0;

    fn construct(_: ?*anyopaque, out: [*]u8) void {
        constructed += 1;
        const value: *u32 = @ptrCast(@alignCast(out));
        value.* = 99;
    }

    fn destruct(_: ?*anyopaque, _: [*]u8) void {
        destructed += 1;
    }

    fn registration() Registration {
        return .{
            .id = .none,
            .schema = .none,
            .name = "test:counted",
            .size = 4,
            .alignment = 4,
            .stride = 4,
            .ctx = null,
            .construct = &construct,
            .destruct = &destruct,
            .deserialize = null,
            .serialize = null,
        };
    }
};

test "construct and destruct run, including on teardown" {
    const gpa = testing.allocator;
    Counted.constructed = 0;
    Counted.destructed = 0;

    {
        var store: ComponentStore = .init(&Counted.registration());
        defer store.deinit(gpa);

        const bytes = try store.add(gpa, e(0, 1), null);
        try testing.expectEqual(@as(u32, 1), Counted.constructed);
        try testing.expectEqual(@as(u32, 99), @as(*const u32, @ptrCast(@alignCast(bytes.ptr))).*);

        _ = try store.add(gpa, e(1, 1), null);
        try testing.expectEqual(@as(u32, 2), Counted.constructed);

        try testing.expect(store.remove(e(0, 1)));
        try testing.expectEqual(@as(u32, 1), Counted.destructed);
    }

    // The one still in the store when it was torn down was destructed too.
    try testing.expectEqual(@as(u32, 2), Counted.destructed);
}

test "supplied bytes are copied rather than constructed over" {
    const gpa = testing.allocator;
    Counted.constructed = 0;
    Counted.destructed = 0;

    var store: ComponentStore = .init(&Counted.registration());
    defer store.deinit(gpa);

    var value: u32 = 5;
    const bytes = try store.add(gpa, e(0, 1), std.mem.asBytes(&value));
    try testing.expectEqual(@as(u32, 5), @as(*const u32, @ptrCast(@alignCast(bytes.ptr))).*);
    // A constructor that ran and was then overwritten would be a double initialisation,
    // which is exactly what a type owning memory cannot survive.
    try testing.expectEqual(@as(u32, 0), Counted.constructed);
}
