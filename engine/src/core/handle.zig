//! Generational handles, and the pool that issues them.
//!
//! Everything addressable is referred to by a `{ index, generation }` handle rather
//! than a pointer (I1, ADR-0005). Lookup validates the generation, so a stale handle
//! fails cleanly instead of reading freed memory — and **failing to resolve is a
//! normal, recoverable condition, never an assertion**, because handles arrive from
//! saves, tools and mods, all of which are untrusted.
//!
//! See `docs/design/core-memory-and-handles.md` §2.

const std = @import("std");
const assert = @import("assert.zig");
const log = @import("log.zig").scoped(.core_handle);

/// A generational handle to a `T`.
///
/// `T` is a phantom tag and is never stored: `Handle(Texture)` and `Handle(Buffer)`
/// are distinct types that cannot be swapped at a call site. This costs nothing at
/// runtime and removes an entire category of bug that bare integer handles invite.
///
/// `extern struct` is deliberate. Handles cross the public C ABI at M7 (ADR-0004),
/// which makes their size and alignment a compatibility decision rather than an
/// implementation detail. The field layout is not part of the published contract —
/// at the ABI a handle is an opaque 64-bit value.
pub fn Handle(comptime T: type) type {
    return extern struct {
        const Self = @This();

        /// The tagged type. Present for generic code; never stored in an instance.
        pub const Target = T;

        index: u32 = 0,
        generation: u32 = 0,

        /// The absence of a handle. All-zero bits, so a zeroed struct is safely
        /// invalid rather than accidentally referring to slot 0.
        pub const none: Self = .{ .index = 0, .generation = 0 };

        /// Generation 0 is reserved for `none`; a live slot never has it.
        pub fn isNone(self: Self) bool {
            return self.generation == 0;
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.index == b.index and a.generation == b.generation;
        }

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (self.isNone()) return writer.print("{s}(none)", .{@typeName(T)});
            try writer.print("{s}({d}#{d})", .{ @typeName(T), self.index, self.generation });
        }

        /// The handle as a single 64-bit value, and back.
        ///
        /// The layout above is not published, but the *width* is: at the ABI a handle is
        /// an opaque 64-bit value (ADR-0004). Anywhere one word has to stand for either a
        /// pointer or a handle — the asset registry's loader payloads are the first such
        /// place — this is the packing, written down once instead of at each site.
        pub fn bits(self: Self) u64 {
            return @as(u64, self.index) | (@as(u64, self.generation) << 32);
        }

        pub fn fromBits(value: u64) Self {
            return .{ .index = @truncate(value), .generation = @truncate(value >> 32) };
        }
    };
}

/// Owns values of type `T` and issues `Handle(T)`.
///
/// Sparse by design: live values are scattered across slots, which suits things looked
/// up by identity and iterated rarely — textures, buffers, windows, loaded packages.
/// It is the *wrong* structure for entity components, which are iterated in bulk every
/// frame; that is a separate design (ADR-0010, M4). Resist generalising this to cover
/// both, which would serve neither well.
/// A pool of `T`, addressed by `Handle(Tag)`.
///
/// **The tag and the stored type are separate on purpose.** A subsystem exposes a
/// public handle over private state — `platform` hands out `Handle(Window)` while
/// storing a `WindowState` nobody outside it can name — and a pool that derived the
/// handle type from the stored type would either leak the private type into the
/// public interface or force a cast at every boundary. Requiring both makes the
/// public identity a deliberate choice, which is what I1 is asking for.
///
/// When a type is its own public identity, pass it twice: `HandlePool(Thing, Thing)`.
pub fn HandlePool(comptime Tag: type, comptime T: type) type {
    return struct {
        const Self = @This();

        /// The public identity of an entry. Distinct from `Handle(Value)`, and that
        /// is the point.
        pub const Id = Handle(Tag);
        pub const Value = T;

        /// Sentinel terminating the free list. Also caps the usable index range, which
        /// is why `add` guards against reaching it.
        const free_list_end: u32 = std.math.maxInt(u32);

        const Slot = struct {
            /// Odd detail worth knowing: this is meaningful whether or not the slot is
            /// occupied. A free slot keeps the generation that will be handed out when
            /// it is next reused.
            generation: u32,
            /// Valid only while the slot is free.
            next_free: u32,
            occupied: bool,
            value: T,
        };

        slots: std.ArrayList(Slot) = .empty,
        free_head: u32 = free_list_end,
        live: u32 = 0,

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.slots.deinit(gpa);
            self.* = .empty;
        }

        /// Number of live values.
        pub fn count(self: *const Self) u32 {
            return self.live;
        }

        /// Number of slots ever allocated. Only grows — indices are stable forever,
        /// which is what makes handles meaningful.
        pub fn capacity(self: *const Self) usize {
            return self.slots.items.len;
        }

        /// Reserves room for `n` more values, so that a run of `add` calls cannot fail
        /// partway.
        ///
        /// For callers that have to be all-or-nothing: a content store merging a package
        /// either takes all of it or none of it, and "ran out of memory halfway" is not a
        /// state worth being able to describe. Free slots are reused before the array
        /// grows, so only the shortfall is reserved.
        pub fn ensureUnusedCapacity(self: *Self, gpa: std.mem.Allocator, n: u32) std.mem.Allocator.Error!void {
            const free = self.slots.items.len - self.live;
            if (free >= n) return;
            try self.slots.ensureUnusedCapacity(gpa, n - free);
        }

        pub fn add(self: *Self, gpa: std.mem.Allocator, value: T) std.mem.Allocator.Error!Id {
            if (self.free_head != free_list_end) {
                const index = self.free_head;
                const slot = &self.slots.items[index];
                self.free_head = slot.next_free;
                slot.next_free = free_list_end;
                slot.occupied = true;
                slot.value = value;
                self.live += 1;
                return .{ .index = index, .generation = slot.generation };
            }

            assert.always(
                self.slots.items.len < free_list_end,
                "handle pool exhausted: {d} slots is the u32 index limit",
                .{self.slots.items.len},
            );

            const index: u32 = @intCast(self.slots.items.len);
            try self.slots.append(gpa, .{
                .generation = 1, // never 0; that is reserved for `none`
                .next_free = free_list_end,
                .occupied = true,
                .value = value,
            });
            self.live += 1;
            return .{ .index = index, .generation = 1 };
        }

        /// Resolves a handle, or returns null if it is stale, null, or out of range.
        ///
        /// The returned pointer is a **borrow, valid only until the next mutation** of
        /// this pool — `add` may reallocate the slot array. Hold the handle, not the
        /// pointer; that is what I1 means in practice.
        pub fn get(self: *Self, id: Id) ?*T {
            const index = self.liveIndex(id) orelse return null;
            return &self.slots.items[index].value;
        }

        pub fn getConst(self: *const Self, id: Id) ?*const T {
            const index = self.liveIndex(id) orelse return null;
            return &self.slots.items[index].value;
        }

        pub fn contains(self: *const Self, id: Id) bool {
            return self.liveIndex(id) != null;
        }

        /// Frees the slot a handle refers to. Returns false if the handle was already
        /// stale — which is not an error, and callers are free to ignore it.
        pub fn remove(self: *Self, id: Id) bool {
            const index = self.liveIndex(id) orelse return false;
            const slot = &self.slots.items[index];

            slot.occupied = false;
            slot.value = undefined;

            slot.generation +%= 1;
            if (slot.generation == 0) {
                // 2^32 reuses of one slot. Roughly two years of allocating and freeing
                // the same slot sixty times a second. We wrap rather than retire the
                // slot, because retiring leaks a slot per wrap to solve a problem that
                // does not occur in practice — but if this ever fires, the assumption
                // was wrong and we would rather learn it from a log line than a bug
                // report.
                slot.generation = 1;
                log.warn(
                    "slot {d} generation wrapped; handles held across 2^32 reuses can now alias",
                    .{index},
                );
            }

            slot.next_free = self.free_head;
            self.free_head = @intCast(index);
            self.live -= 1;
            return true;
        }

        fn liveIndex(self: *const Self, id: Id) ?usize {
            if (id.isNone()) return null;
            if (id.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[id.index];
            if (!slot.occupied) return null;
            if (slot.generation != id.generation) return null;
            return id.index;
        }

        pub const Entry = struct { id: Id, value: *T };

        /// Iterates live entries in **ascending slot index** order.
        ///
        /// Stable and documented, as I9 requires wherever order affects outcomes.
        /// Deliberately not insertion order: because the free list is LIFO, a reused
        /// slot returns to its old position, so freeing and re-adding changes the order.
        /// That is deterministic — the same operations always produce the same order —
        /// but it is not intuitive, and any system whose *results* depend on it must
        /// say so.
        pub const Iterator = struct {
            pool: *Self,
            next_index: usize = 0,

            pub fn next(self: *Iterator) ?Entry {
                while (self.next_index < self.pool.slots.items.len) {
                    const index = self.next_index;
                    self.next_index += 1;
                    const slot = &self.pool.slots.items[index];
                    if (!slot.occupied) continue;
                    return .{
                        .id = .{ .index = @intCast(index), .generation = slot.generation },
                        .value = &slot.value,
                    };
                }
                return null;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{ .pool = self };
        }

        // -- snapshot and restore ----------------------------------------------

        /// One slot exactly as the pool holds it: the generation it will hand out next,
        /// and its value when it is occupied.
        ///
        /// Not "an optional slot". A **free** slot's generation is meaningful — it is the
        /// generation the slot will be reused at, and it is the whole mechanism by which
        /// a stale handle stays stale — so a snapshot that dropped it would produce a pool
        /// that reissues handles somebody is still holding.
        pub const Snapshot = struct { generation: u32, value: ?T };

        pub const RestoreError = error{
            /// The slots and the free list are not a pool: a generation of zero, a
            /// free-list entry out of range, repeated, or naming an occupied slot, or a
            /// free list that does not account for every unoccupied slot.
            InvalidSnapshot,
        } || std.mem.Allocator.Error;

        /// Every slot in index order, occupied or not. Null past the end.
        ///
        /// The saving half of `restore`, and deliberately a slot-indexed read rather than
        /// an iterator: what a save writes is one entry per slot, including the free ones,
        /// which is precisely what `iterator` skips.
        pub fn slotAt(self: *const Self, index: u32) ?Snapshot {
            if (index >= self.slots.items.len) return null;
            const slot = &self.slots.items[index];
            return .{
                .generation = slot.generation,
                .value = if (slot.occupied) slot.value else null,
            };
        }

        /// The free list in the order `add` will consume it, head first.
        pub const FreeIterator = struct {
            pool: *const Self,
            next_index: u32,

            pub fn next(self: *FreeIterator) ?u32 {
                if (self.next_index == free_list_end) return null;
                const index = self.next_index;
                self.next_index = self.pool.slots.items[index].next_free;
                return index;
            }
        };

        pub fn freeSlots(self: *const Self) FreeIterator {
            return .{ .pool = self, .next_index = self.free_head };
        }

        /// Rebuilds a pool's exact state from a snapshot.
        ///
        /// **The only way to make a pool hand out a handle it did not issue**, and
        /// therefore the only way a save can preserve identity across a reload: a world
        /// reloaded from disk answers for the same entity handles the original would have,
        /// so a handle stored inside saved data needs no remapping pass
        /// (`entity-storage.md` §9).
        ///
        /// It is also the one entry point whose input is not the pool's own — a save is a
        /// file somebody else can write — so it **validates rather than asserts**, and a
        /// refused snapshot leaves the pool untouched. Restoring over a populated pool is
        /// a different matter and is a caller bug: it asserts.
        pub fn restore(
            self: *Self,
            gpa: std.mem.Allocator,
            slots: []const Snapshot,
            free_list: []const u32,
        ) RestoreError!void {
            assert.always(
                self.slots.items.len == 0,
                "restore into a pool holding {d} slots; restore is for a fresh pool",
                .{self.slots.items.len},
            );
            if (slots.len >= free_list_end) return error.InvalidSnapshot;
            if (free_list.len > slots.len) return error.InvalidSnapshot;

            var live: u32 = 0;
            for (slots) |s| {
                // Generation 0 is `none`. A slot holding it would answer a null handle.
                if (s.generation == 0) return error.InvalidSnapshot;
                if (s.value != null) live += 1;
            }
            if (slots.len - free_list.len != live) return error.InvalidSnapshot;

            // Every free-list entry has to be a distinct unoccupied slot. With the count
            // above agreeing, that is enough to know the list is exactly the free slots.
            const seen = try gpa.alloc(bool, slots.len);
            defer gpa.free(seen);
            @memset(seen, false);
            for (free_list) |index| {
                if (index >= slots.len) return error.InvalidSnapshot;
                if (slots[index].value != null) return error.InvalidSnapshot;
                if (seen[index]) return error.InvalidSnapshot;
                seen[index] = true;
            }

            // Nothing is written until everything has been checked, so a refusal leaves
            // the pool as it was.
            var built: std.ArrayList(Slot) = .empty;
            errdefer built.deinit(gpa);
            try built.ensureTotalCapacityPrecise(gpa, slots.len);
            for (slots) |s| built.appendAssumeCapacity(.{
                .generation = s.generation,
                .next_free = free_list_end,
                .occupied = s.value != null,
                .value = if (s.value) |v| v else undefined,
            });

            // Walked backwards so each entry can point at the one after it.
            var head = free_list_end;
            var i = free_list.len;
            while (i > 0) {
                i -= 1;
                built.items[free_list[i]].next_free = head;
                head = free_list[i];
            }

            self.slots = built;
            self.free_head = head;
            self.live = live;
        }
    };
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

const Thing = struct { n: u32 };
const ThingPool = HandlePool(Thing, Thing);

test "handle layout is stable and C-compatible" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Handle(Thing)));
    try testing.expectEqual(@as(usize, 4), @alignOf(Handle(Thing)));
}

test "a zeroed handle is none" {
    const zeroed: Handle(Thing) = .{};
    try testing.expect(zeroed.isNone());
    try testing.expect(std.mem.zeroes(Handle(Thing)).isNone());
    try testing.expect(Handle(Thing).none.isNone());
}

test "a handle survives a round trip through 64 bits" {
    const h: Handle(Thing) = .{ .index = 7, .generation = 3 };
    try testing.expect(h.eql(Handle(Thing).fromBits(h.bits())));

    // `none` is all-zero bits, and stays that way through the packing — so a zeroed
    // payload word is an absent handle rather than slot 0.
    try testing.expectEqual(@as(u64, 0), Handle(Thing).none.bits());
    try testing.expect(Handle(Thing).fromBits(0).isNone());

    // Both halves are carried, not just the index: a stale handle must not come back
    // looking live.
    const max: Handle(Thing) = .{ .index = 0xFFFF_FFFF, .generation = 0xFFFF_FFFF };
    try testing.expect(max.eql(Handle(Thing).fromBits(max.bits())));
}

test "handles of different targets are different types" {
    const Other = struct { x: u8 };
    try testing.expect(Handle(Thing) != Handle(Other));
}

test "add, resolve, remove" {
    const gpa = testing.allocator;
    var pool: ThingPool = .empty;
    defer pool.deinit(gpa);

    const a = try pool.add(gpa, .{ .n = 10 });
    const b = try pool.add(gpa, .{ .n = 20 });

    try testing.expectEqual(@as(u32, 2), pool.count());
    try testing.expectEqual(@as(u32, 10), pool.get(a).?.n);
    try testing.expectEqual(@as(u32, 20), pool.get(b).?.n);

    try testing.expect(pool.remove(a));
    try testing.expectEqual(@as(u32, 1), pool.count());
    try testing.expect(pool.get(a) == null);
    try testing.expect(!pool.contains(a));
    try testing.expectEqual(@as(u32, 20), pool.get(b).?.n);
}

test "a stale handle resolves to null rather than the new occupant" {
    const gpa = testing.allocator;
    var pool: ThingPool = .empty;
    defer pool.deinit(gpa);

    const first = try pool.add(gpa, .{ .n = 1 });
    try testing.expect(pool.remove(first));

    // The slot is reused, so the index matches — only the generation differs.
    const second = try pool.add(gpa, .{ .n = 2 });
    try testing.expectEqual(first.index, second.index);
    try testing.expect(first.generation != second.generation);

    try testing.expect(pool.get(first) == null);
    try testing.expectEqual(@as(u32, 2), pool.get(second).?.n);
}

test "removing an already stale handle is false, not a crash" {
    const gpa = testing.allocator;
    var pool: ThingPool = .empty;
    defer pool.deinit(gpa);

    const h = try pool.add(gpa, .{ .n = 1 });
    try testing.expect(pool.remove(h));
    try testing.expect(!pool.remove(h));
    try testing.expect(!pool.remove(ThingPool.Id.none));
    try testing.expect(!pool.remove(.{ .index = 9999, .generation = 1 }));
}

test "the null handle never resolves, even to slot 0" {
    const gpa = testing.allocator;
    var pool: ThingPool = .empty;
    defer pool.deinit(gpa);

    const zero_slot = try pool.add(gpa, .{ .n = 7 });
    try testing.expectEqual(@as(u32, 0), zero_slot.index);
    try testing.expect(pool.get(ThingPool.Id.none) == null);
    try testing.expectEqual(@as(u32, 7), pool.get(zero_slot).?.n);
}

test "iteration is ascending by slot index" {
    const gpa = testing.allocator;
    var pool: ThingPool = .empty;
    defer pool.deinit(gpa);

    const a = try pool.add(gpa, .{ .n = 0 });
    _ = try pool.add(gpa, .{ .n = 1 });
    const c = try pool.add(gpa, .{ .n = 2 });
    _ = try pool.add(gpa, .{ .n = 3 });

    try testing.expect(pool.remove(a));
    try testing.expect(pool.remove(c));

    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(gpa);
    var it = pool.iterator();
    while (it.next()) |entry| try seen.append(gpa, entry.value.n);

    try testing.expectEqualSlices(u32, &.{ 1, 3 }, seen.items);
}

test "freed slots are reused LIFO, which reorders iteration deterministically" {
    const gpa = testing.allocator;
    var pool: ThingPool = .empty;
    defer pool.deinit(gpa);

    const a = try pool.add(gpa, .{ .n = 0 });
    const b = try pool.add(gpa, .{ .n = 1 });
    _ = try pool.add(gpa, .{ .n = 2 });

    try testing.expect(pool.remove(a)); // free list: 0
    try testing.expect(pool.remove(b)); // free list: 1 -> 0

    // LIFO: the most recently freed slot is handed out first.
    const reused = try pool.add(gpa, .{ .n = 99 });
    try testing.expectEqual(b.index, reused.index);

    // And the new value appears at slot 1's position, not at the end.
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(gpa);
    var it = pool.iterator();
    while (it.next()) |entry| try seen.append(gpa, entry.value.n);
    try testing.expectEqualSlices(u32, &.{ 99, 2 }, seen.items);
}

test "generation wraparound skips 0 and keeps the pool usable" {
    const gpa = testing.allocator;
    var pool: ThingPool = .empty;
    defer pool.deinit(gpa);

    const first = try pool.add(gpa, .{ .n = 0 });
    // Drive the slot's generation to the value just before wrapping, rather than
    // performing 2^32 add/remove cycles.
    pool.slots.items[first.index].generation = std.math.maxInt(u32);
    const pre_wrap = ThingPool.Id{ .index = first.index, .generation = std.math.maxInt(u32) };

    try testing.expect(pool.remove(pre_wrap));
    try testing.expectEqual(@as(u32, 1), pool.slots.items[first.index].generation);

    const after = try pool.add(gpa, .{ .n = 5 });
    try testing.expect(!after.isNone());
    try testing.expectEqual(@as(u32, 5), pool.get(after).?.n);
}

test "capacity only grows; indices stay stable" {
    const gpa = testing.allocator;
    var pool: ThingPool = .empty;
    defer pool.deinit(gpa);

    const a = try pool.add(gpa, .{ .n = 1 });
    _ = try pool.add(gpa, .{ .n = 2 });
    try testing.expectEqual(@as(usize, 2), pool.capacity());

    try testing.expect(pool.remove(a));
    try testing.expectEqual(@as(usize, 2), pool.capacity());
    try testing.expectEqual(@as(u32, 1), pool.count());

    _ = try pool.add(gpa, .{ .n = 3 });
    try testing.expectEqual(@as(usize, 2), pool.capacity()); // reused, not grown
}

test "reserving counts the free slots it is about to reuse" {
    const gpa = testing.allocator;
    var pool: ThingPool = .empty;
    defer pool.deinit(gpa);

    const a = try pool.add(gpa, .{ .n = 1 });
    const b = try pool.add(gpa, .{ .n = 2 });
    try testing.expect(pool.remove(a));
    try testing.expect(pool.remove(b));

    // Two free slots already cover two more values, so nothing is allocated...
    try pool.ensureUnusedCapacity(gpa, 2);
    try testing.expectEqual(@as(usize, 2), pool.capacity());

    // ...and asking for four reserves only the two the free list cannot supply.
    try pool.ensureUnusedCapacity(gpa, 4);
    const reserved = pool.slots.capacity;
    try testing.expect(reserved >= 4);
    for (0..4) |i| _ = try pool.add(gpa, .{ .n = @intCast(i) });
    try testing.expectEqual(reserved, pool.slots.capacity);
}

// -- snapshot and restore ----------------------------------------------------------

/// Copies a pool's whole state out, the way a save writes it.
fn snapshotOf(gpa: std.mem.Allocator, pool: *const ThingPool) !struct {
    slots: []ThingPool.Snapshot,
    free: []u32,
} {
    const slots = try gpa.alloc(ThingPool.Snapshot, pool.capacity());
    for (slots, 0..) |*s, i| s.* = pool.slotAt(@intCast(i)).?;

    var free: std.ArrayList(u32) = .empty;
    var it = pool.freeSlots();
    while (it.next()) |index| try free.append(gpa, index);
    return .{ .slots = slots, .free = try free.toOwnedSlice(gpa) };
}

test "a restored pool answers for exactly the handles the original did" {
    const gpa = testing.allocator;
    var pool: ThingPool = .empty;
    defer pool.deinit(gpa);

    const a = try pool.add(gpa, .{ .n = 1 });
    const b = try pool.add(gpa, .{ .n = 2 });
    const c = try pool.add(gpa, .{ .n = 3 });
    try testing.expect(pool.remove(b));
    const d = try pool.add(gpa, .{ .n = 4 }); // reuses b's slot at a new generation

    const snap = try snapshotOf(gpa, &pool);
    defer gpa.free(snap.slots);
    defer gpa.free(snap.free);

    var copy: ThingPool = .empty;
    defer copy.deinit(gpa);
    try copy.restore(gpa, snap.slots, snap.free);

    try testing.expectEqual(pool.count(), copy.count());
    try testing.expectEqual(pool.capacity(), copy.capacity());
    for ([_]ThingPool.Id{ a, c, d }) |id| {
        try testing.expectEqual(pool.getConst(id).?.n, copy.getConst(id).?.n);
    }
    // And the stale one is still stale, which is the half a naive copy loses.
    try testing.expect(copy.getConst(b) == null);
}

test "a restored pool hands out the next handle the original would have" {
    const gpa = testing.allocator;
    var pool: ThingPool = .empty;
    defer pool.deinit(gpa);

    const a = try pool.add(gpa, .{ .n = 1 });
    _ = try pool.add(gpa, .{ .n = 2 });
    try testing.expect(pool.remove(a));

    const snap = try snapshotOf(gpa, &pool);
    defer gpa.free(snap.slots);
    defer gpa.free(snap.free);

    var copy: ThingPool = .empty;
    defer copy.deinit(gpa);
    try copy.restore(gpa, snap.slots, snap.free);

    const next_original = try pool.add(gpa, .{ .n = 9 });
    const next_copy = try copy.add(gpa, .{ .n = 9 });
    try testing.expect(next_original.eql(next_copy));
}

test "restore refuses a snapshot that is not a pool" {
    const gpa = testing.allocator;

    const cases = [_]struct { slots: []const ThingPool.Snapshot, free: []const u32 }{
        // Generation zero would answer a `none` handle.
        .{ .slots = &.{.{ .generation = 0, .value = .{ .n = 1 } }}, .free = &.{} },
        // A free-list entry past the end.
        .{ .slots = &.{.{ .generation = 1, .value = null }}, .free = &.{7} },
        // A free-list entry naming an occupied slot.
        .{ .slots = &.{.{ .generation = 1, .value = .{ .n = 1 } }}, .free = &.{0} },
        // One free slot named twice, which would make the free list a cycle.
        .{ .slots = &.{
            .{ .generation = 1, .value = null },
            .{ .generation = 1, .value = null },
        }, .free = &.{ 0, 0 } },
        // A free slot the list does not account for: `add` would never reuse it.
        .{ .slots = &.{
            .{ .generation = 1, .value = null },
            .{ .generation = 1, .value = null },
        }, .free = &.{0} },
    };

    for (cases) |case| {
        var pool: ThingPool = .empty;
        defer pool.deinit(gpa);
        try testing.expectError(error.InvalidSnapshot, pool.restore(gpa, case.slots, case.free));
        // Refused leaves the pool as it was, so a caller can report and carry on.
        try testing.expectEqual(@as(usize, 0), pool.capacity());
    }
}

test "an empty pool round-trips" {
    const gpa = testing.allocator;
    var pool: ThingPool = .empty;
    defer pool.deinit(gpa);
    try pool.restore(gpa, &.{}, &.{});
    try testing.expectEqual(@as(u32, 0), pool.count());
    const first = try pool.add(gpa, .{ .n = 1 });
    try testing.expectEqual(@as(u32, 0), first.index);
    try testing.expectEqual(@as(u32, 1), first.generation);
}
