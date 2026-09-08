//! What the host hands `abi`, and the one place a table's functions find it.
//!
//! **The host supplies the subsystems** (ADR-0026). `abi` creates no engine, no world, no
//! renderer, no mixer and no collision world — a game hands it the ones it has, and a
//! capability whose subsystem is absent answers `unavailable` rather than being a null
//! function pointer. That is not a convenience: `app` owns none of them either, which is the
//! whole reason this module is a peer of `debug` rather than a layer over `app`.
//!
//! **Generic over the engine's type, for the reason `EngineOf` is generic over its ports.**
//! `app.Engine` is `EngineOf(platform.Platform, rhi.Device)`, and a `Host` that named it
//! would drag a window and a device into every test of a call that reads a record. A test
//! binds a fake engine instead, and `abi`'s unit tests run with no window, no device and no
//! frame — the same argument the null RHI backend makes one layer down.
//!
//! **The binding is ambient, because the table has no context parameter.** `FoundryApi_v1`'s
//! functions take handles and values and nothing else (`public-abi.md` §4), so there is one
//! host per process and these functions find it here. That is the same shape `app.log_sink`
//! already has and for the same reason: `std.log` reaches it from code with no pointer to
//! ask. §18's fourth open question — a table per mod, so that policy could differ per
//! consumer — stays open; `_v1` being shared does not foreclose it.
//!
//! Design: `docs/design/public-abi.md` §4, §9 and §13.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const scene = @import("scene");

const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const log = core.log.scoped(.abi);

/// The most counters one host will open for mods, and the longest name one may carry.
///
/// Fixed rather than allocated, and that is the decision. A counter is registered with the
/// engine **by pointer** and its name is borrowed by the report that prints it, so both have
/// to outlive every frame that reads them; storing them inline in the host makes that true
/// by construction instead of by an allocator nobody would think to check. The cost is a
/// bound, and a bound that is hit is a refusal with a name (`limit`) rather than a surprise.
pub const max_counters: u32 = 16;
pub const max_counter_name: u32 = 48;

/// Callback records are host-owned because `scene` borrows its callback context for the
/// lifetime of the world. The bounds are intentionally below the world's limits: this is
/// metadata only for types and systems a native mod registered through this ABI.
pub const max_component_callbacks: u32 = 64;
pub const max_system_callbacks: u32 = 64;
pub const max_queries: u32 = 64;
/// M7 leaves native libraries mapped for the life of the process. This is therefore the
/// process-lifetime limit on identities the native loader may issue.
pub const max_mods: u32 = 64;

/// How many nested blocks a mod may have open views on at once.
///
/// A `FoundryRecord` for a top-level record is the store's own handle and needs no storage.
/// A **nested** block has no identity of its own — that is what nested means — and its view
/// is three slices into a package's bytes, which does not fit in sixty-four bits. So the
/// boundary keeps a ring of them and hands out generational handles into it.
///
/// The consequence is a rule worth stating plainly: **a nested view stays valid until this
/// many more are opened**, and one that has been recycled answers `invalid_handle` rather
/// than reading whatever now occupies the slot. That is I1's promise applied to a view rather
/// than an object, and sixty-four is far more than reading one record needs.
pub const max_nested_views: u32 = 64;

/// How deeply a mod may nest profiler spans before the boundary stops counting.
///
/// `core.profile` already survives an unbalanced span — it closes what is open at the frame
/// boundary — so this is not what protects the recorder. It is what lets `scope_end` refuse
/// to close a span the *engine or the game* opened, which the recorder cannot tell apart.
pub const max_scope_depth: u32 = 32;

/// A `Host` bound to a particular engine type.
pub fn HostOf(comptime E: type) type {
    return struct {
        const Self = @This();

        /// The engine: the frame, the profiler, the memory report, the content store, the
        /// schema registry and the asset registry. Optional like everything else, because a
        /// tool that only wants to read a package is a legitimate host.
        engine: ?*E = null,

        /// The world's ownership stays with the game. Its presence turns on the `scene`
        /// group; its absence is an `unavailable` answer, never a missing table entry.
        world: ?*scene.World = null,

        // Step 5 adds `renderer`, `mixer` and `collision` here. Each is optional and each
        // absence is an `unavailable` answer, never a missing entry.

        /// Counters opened by mods, and registered with the engine on their behalf.
        counters: [max_counters]Counter = @splat(.{}),
        counter_count: u32 = 0,

        /// Open views on nested blocks, as a ring.
        nested: [max_nested_views]NestedView = @splat(.{}),
        nested_next: u32 = 0,

        /// How many profiler spans this boundary has open. Not the recorder's depth — the
        /// recorder counts the engine's and the game's too, and this must not close one of
        /// those.
        scope_depth: u32 = 0,

        /// Stable callback contexts for component types and systems native mods register.
        components: [max_component_callbacks]Component = @splat(.{}),
        systems: [max_system_callbacks]System = @splat(.{}),

        /// Queries borrow the world's stores and have mutable progress, so a cursor names a
        /// host-owned slot rather than exposing `scene.Query` itself.
        queries: [max_queries]Query = @splat(.{}),
        query_next: u32 = 0,

        /// Identities handed to native libraries at `foundry_mod_init`. A mod can receive
        /// one but cannot manufacture one through the API.
        mods: [max_mods]ModSlot = @splat(.{}),
        mod_next: u32 = 0,

        /// The bound host, which is what a table's functions find. One per process and per
        /// engine type; binding a second replaces the first and says so.
        var bound: ?*Self = null;

        /// One borrowed view of a nested block.
        pub const NestedView = struct {
            /// Bumped every time the slot is reused, so a handle to a recycled view fails to
            /// resolve. Zero means the slot has never been used.
            generation: u32 = 0,
            /// What the content generation was when the view was opened. A reload rebuilds
            /// the store and the package bytes underneath, so a view that survived one is
            /// pointing at memory that has been freed — and this is what notices.
            content_generation: u64 = 0,
            /// The frame the view was opened in, for a view over memory the **frame arena**
            /// owns rather than a loaded package's: `world_read_component` serializes a
            /// component into the arena, and the next `beginFrame` reclaims it. Null for a
            /// view into package bytes, which live until a reload and are what
            /// `content_generation` above guards.
            ///
            /// Two lifetimes rather than one because they really are two: a content view is
            /// legitimately usable across frames and a described component never is.
            frame: ?u64 = null,
            fields: data.fpk.Fields = undefined,
            /// The schema the block is laid out against: the parent field's `nested` list.
            schema: data.Schema = undefined,
        };

        /// Set on a record handle's index to say the handle names a nested view rather than
        /// a record in the store.
        ///
        /// The store's own indices come from a pool that grows one slot at a time, so
        /// reaching two billion records is not a thing that happens; the top bit is free and
        /// using it keeps `FoundryRecord` sixty-four opaque bits, which is what every other
        /// handle at this boundary is.
        pub const nested_flag: u32 = 0x8000_0000;

        /// Opens a view on a nested block and hands back the handle that names it.
        pub fn openNested(
            self: *Self,
            content_generation: u64,
            frame: ?u64,
            fields: data.fpk.Fields,
            schema: data.Schema,
        ) types.Record {
            const slot = self.nested_next;
            self.nested_next = (slot + 1) % max_nested_views;

            const view = &self.nested[slot];
            view.generation +%= 1;
            if (view.generation == 0) view.generation = 1;
            view.content_generation = content_generation;
            view.frame = frame;
            view.fields = fields;
            view.schema = schema;

            const handle: core.Handle(NestedView) = .{
                .index = slot | nested_flag,
                .generation = view.generation,
            };
            return .{ .bits = handle.bits() };
        }

        /// Whether a record handle names a nested view at all.
        pub fn namesNested(handle: types.Record) bool {
            return handle.unwrap(core.Handle(NestedView)).index & nested_flag != 0;
        }

        /// Resolves one, or null for a view that was recycled, never issued, or opened
        /// against content that has since been reloaded.
        pub fn nestedView(
            self: *Self,
            handle: types.Record,
            content_generation: u64,
            frame: u64,
        ) ?*const NestedView {
            const unpacked = handle.unwrap(core.Handle(NestedView));
            if (unpacked.index & nested_flag == 0) return null;

            const slot = unpacked.index & ~nested_flag;
            if (slot >= max_nested_views) return null;

            const view = &self.nested[slot];
            if (view.generation == 0 or view.generation != unpacked.generation) return null;
            if (view.content_generation != content_generation) return null;
            if (view.frame) |opened| {
                if (opened != frame) return null;
            }
            return view;
        }

        pub const Counter = struct {
            open: bool = false,
            /// The engine holds a **pointer** to this, so the host must not move after
            /// `bind`. `bind` takes `*Self`, which is what makes that visible at the call
            /// site rather than only here.
            counted: core.mem.Counted = .{ .name = "", .child = noAllocator() },
            name_buffer: [max_counter_name]u8 = @splat(0),
            /// What the engine gave back, so `unbind` can take it away again.
            registration: ?RegistrationOf(E) = null,
            /// Which mod opened it. Diagnostics for now; the seed of what would be
            /// unregistered if a mod ever became unloadable (§14).
            owner: types.Mod = .none,
        };

        pub const Component = struct {
            active: bool = false,
            owner: types.Mod = .none,
            type: scene.ComponentType = .none,
            ctx: ?*anyopaque = null,
            construct: ?types.ComponentConstruct = null,
            destruct: ?types.ComponentDestruct = null,
        };

        pub const System = struct {
            active: bool = false,
            owner: types.Mod = .none,
            ctx: ?*anyopaque = null,
            update: ?types.SystemUpdate = null,
        };

        pub const Query = struct {
            generation: u32 = 0,
            inner: scene.Query = undefined,
        };

        const ModSlot = struct {
            active: bool = false,
            generation: u32 = 0,
        };

        /// Publishes this host to the table. **The host must outlive the binding and must
        /// not be moved**, because the engine holds pointers into its counters.
        pub fn bind(self: *Self) void {
            if (bound) |previous| {
                if (previous != self) log.warn("a second host was bound; the first is replaced", .{});
            }
            bound = self;
        }

        /// Issue a process-lifetime identity to a library about to run. M7 deliberately
        /// never unloads a native mod, so reusing a slot would make an old callback's
        /// `self` name a different library — exactly the stale-handle failure I1 forbids.
        pub fn issueMod(self: *Self) ?types.Mod {
            var tried: u32 = 0;
            while (tried < max_mods) : (tried += 1) {
                const index = self.mod_next;
                self.mod_next = (self.mod_next + 1) % max_mods;
                const slot = &self.mods[index];
                if (slot.active) continue;
                slot.generation +%= 1;
                if (slot.generation == 0) slot.generation = 1;
                slot.active = true;
                return .wrap(core.Handle(ModSlot){ .index = index, .generation = slot.generation });
            }
            return null;
        }

        /// Takes the host away and hands back everything it registered on a mod's behalf.
        ///
        /// Unregistering here rather than leaving it to teardown is the point: the counters
        /// are the host's memory, and an engine still holding pointers into a host that has
        /// gone is exactly the failure this whole module exists to make impossible.
        pub fn unbind(self: *Self) void {
            self.releaseCounters();
            self.nested = @splat(.{});
            self.nested_next = 0;
            self.components = @splat(.{});
            self.systems = @splat(.{});
            self.queries = @splat(.{});
            self.query_next = 0;
            self.mods = @splat(.{});
            self.mod_next = 0;
            if (bound == self) bound = null;
        }

        /// Forgets whatever is bound, without needing it. For a teardown path that has lost
        /// track of the host, and for a test that has to prove what an unbound table does.
        pub fn unbindAny() void {
            bound = null;
        }

        /// The bound host, or null when nothing has been bound. Every entry point starts
        /// here, and a null answer is `unavailable` rather than a crash: a mod's library
        /// stays loaded for the life of the process (§14), so a call after teardown is a
        /// case that can actually happen.
        pub fn current() ?*Self {
            return bound;
        }

        /// Opens a counter for `owner`, copying the name.
        pub fn openCounter(self: *Self, owner: types.Mod, name: []const u8) error{ Limit, Unavailable, OutOfMemory }!types.MemoryCounter {
            if (name.len == 0 or name.len > max_counter_name) return error.Limit;
            const engine = self.engine orelse return error.Unavailable;

            const slot = for (self.counters[0..], 0..) |*c, i| {
                if (!c.open) break @as(u32, @intCast(i));
            } else return error.Limit;

            const entry = &self.counters[slot];
            @memcpy(entry.name_buffer[0..name.len], name);
            entry.counted = .{ .name = entry.name_buffer[0..name.len], .child = noAllocator() };
            entry.owner = owner;
            entry.registration = try engine.registerMemory(&entry.counted);
            entry.open = true;
            self.counter_count += 1;

            // Generation 1 for every counter, because a counter is never released
            // individually in `_v1` — `unbind` releases all of them at once. The field is
            // still there, and the day a counter can be closed is the day it starts moving.
            return .{ .bits = (core.Handle(Counter){ .index = slot, .generation = 1 }).bits() };
        }

        /// Resolves a counter handle. Null for anything that was never issued, which is what
        /// makes a handle from a mod safe to receive.
        pub fn counter(self: *Self, handle: types.MemoryCounter) ?*Counter {
            const unpacked = handle.unwrap(core.Handle(Counter));
            if (unpacked.generation != 1) return null;
            if (unpacked.index >= max_counters) return null;
            const c = &self.counters[unpacked.index];
            if (!c.open) return null;
            return c;
        }

        /// Reserves a stable context before `scene` records its callbacks. A failed world
        /// registration is discarded by the caller, so no unused record remains visible.
        pub fn openComponent(self: *Self, owner: types.Mod, desc: types.ComponentDesc) ?*Component {
            const slot = for (self.components[0..]) |*component| {
                if (!component.active) break component;
            } else return null;

            slot.* = .{
                .active = true,
                .owner = owner,
                .ctx = desc.ctx,
                .construct = desc.construct,
                .destruct = desc.destruct,
            };
            return slot;
        }

        pub fn closeComponent(_: *Self, component: *Component) void {
            component.* = .{};
        }

        pub fn ownComponent(self: *const Self, owner: types.Mod, t: scene.ComponentType) bool {
            for (self.components) |component| {
                if (component.active and component.owner.eql(owner) and component.type.eql(t)) return true;
            }
            return false;
        }

        /// `scene` calls these with the slot as its context, so **the host must outlive
        /// every world it was lent to**: the world keeps registrations pointing here.
        ///
        /// A released slot is a no-op rather than a null call. A host that unbinds while a
        /// world still holds its registrations has made a mistake, and the ABI's job at that
        /// point is to not be the thing that crashes — which is the same rule every entry
        /// point above follows, applied to the direction the calls run the other way.
        pub fn componentConstruct(ctx: ?*anyopaque, out: [*]u8) void {
            const slot: *Component = @ptrCast(@alignCast(ctx.?));
            const construct = slot.construct orelse return;
            construct(slot.ctx, @ptrCast(out));
        }

        pub fn componentDestruct(ctx: ?*anyopaque, bytes: [*]u8) void {
            const slot: *Component = @ptrCast(@alignCast(ctx.?));
            const destruct = slot.destruct orelse return;
            destruct(slot.ctx, @ptrCast(bytes));
        }

        pub fn openSystem(self: *Self, owner: types.Mod, desc: types.SystemDesc) ?*System {
            const slot = for (self.systems[0..]) |*system| {
                if (!system.active) break system;
            } else return null;

            slot.* = .{
                .active = true,
                .owner = owner,
                .ctx = desc.ctx,
                .update = desc.update,
            };
            return slot;
        }

        pub fn closeSystem(_: *Self, system: *System) void {
            system.* = .{};
        }

        /// The world is dropped rather than passed on: a native system reaches it through
        /// the table it kept from init, so no engine pointer crosses and `scene` never
        /// learns that one of its systems came from outside the process image.
        pub fn systemUpdate(ctx: ?*anyopaque, _: *scene.World, tick: scene.Tick) void {
            const slot: *System = @ptrCast(@alignCast(ctx.?));
            const update = slot.update orelse return;
            const step: types.Step = .{ .tick = tick.tick, .delta_ns = @intCast(tick.delta.ns) };
            update(slot.ctx, &step);
        }

        pub fn openQuery(self: *Self, opened: scene.Query) types.Cursor {
            const slot = self.query_next;
            self.query_next = (slot + 1) % max_queries;

            const entry = &self.queries[slot];
            entry.generation +%= 1;
            if (entry.generation == 0) entry.generation = 1;
            entry.inner = opened;

            return .{ .bits = (core.Handle(Query){ .index = slot, .generation = entry.generation }).bits() };
        }

        pub fn query(self: *Self, cursor: types.Cursor) ?*Query {
            const handle = core.Handle(Query).fromBits(cursor.bits);
            if (handle.generation == 0 or handle.index >= max_queries) return null;
            const entry = &self.queries[handle.index];
            if (entry.generation != handle.generation) return null;
            return entry;
        }

        fn releaseCounters(self: *Self) void {
            for (self.counters[0..]) |*c| {
                if (!c.open) continue;
                if (c.registration) |handle| {
                    if (self.engine) |engine| engine.unregisterMemory(handle);
                }
                c.* = .{};
            }
            self.counter_count = 0;
        }
    };
}

/// The type `E.registerMemory` hands back, named without naming `app`.
///
/// `abi` does import `app`, so this could have been `app.MemoryHandle` — but writing it this
/// way is what lets a test bind a fake engine whose handle type is its own, and a `Host` that
/// only worked for one engine type would have defeated the reason it is generic at all.
fn RegistrationOf(comptime E: type) type {
    return @typeInfo(@typeInfo(@TypeOf(E.registerMemory)).@"fn".return_type.?).error_union.payload;
}

/// An allocator that allocates nothing, for a `core.mem.Counted` nobody allocates through.
///
/// A mod's counter is a *report*, not a wrapper: the ABI cannot wrap a mod's allocator,
/// because a native mod allocates however its own language does. So the `Counted` here is
/// only ever written to by `memory_counter_set` and read by the memory report, and the child
/// allocator exists to satisfy the type. Making it refuse rather than leaving it undefined
/// means a mistake is a null return instead of a jump through uninitialised memory.
fn noAllocator() Allocator {
    const vtable: Allocator.VTable = .{
        .alloc = struct {
            fn f(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
                return null;
            }
        }.f,
        .resize = struct {
            fn f(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
                return false;
            }
        }.f,
        .remap = struct {
            fn f(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
                return null;
            }
        }.f,
        .free = struct {
            fn f(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
        }.f,
    };
    return .{ .ptr = undefined, .vtable = &vtable };
}
