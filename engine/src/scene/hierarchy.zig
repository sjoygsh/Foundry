//! The engine's transform hierarchy: `foundry:transform`, `foundry:parent` and
//! `foundry:world_transform` (ADR-0050, `docs/design/hierarchy.md`).
//!
//! **The first engine-declared component types.** M5 declared none, so that no name was
//! chosen before a game said what belonged on it. A 3D hierarchy is the exception ADR-0050
//! makes: propagation, collision sync, animation and render extraction all need one answer to
//! "where is this, relative to what", and a mod could not attach to another's object if each
//! invented its own. Every name below is permanent (CLAUDE.md §7).
//!
//! **A world opts in** with `World.enableHierarchy`, which registers the three types and
//! remembers them, so that rules that must hold for every caller of the world (the despawn
//! cascade, Step 3) can. A 2D world never calls it and never carries them (§3.1).
//!
//! **Propagation** (§4) turns local poses into world matrices, parents before children, and
//! is a function of the world's contents alone. It and `worldOf` hold §6's rules against data
//! no call validated: a save, a mod's raw component write, a hand-edited file.
//!
//! **Re-parenting** (§5) is `setParent`, which keeps the local pose, and `setParentKeepWorld`,
//! which keeps the world pose exactly or refuses. Either checks everything before it writes
//! anything. **The despawn cascade** is `World.destroy`'s, over `descendants` here.

const std = @import("std");
const core = @import("core");
const data = @import("data");

const component = @import("component.zig");
const derive = @import("derive.zig");
const entity_mod = @import("entity.zig");
const system_mod = @import("system.zig");
const world_mod = @import("world.zig");

const Allocator = std.mem.Allocator;
const World = world_mod.World;
const log = core.log.scoped(.scene);

const ComponentType = component.ComponentType;
const ComponentTypeInfo = component.ComponentTypeInfo;
const Entity = entity_mod.Entity;
const Mat4 = core.math.Mat4;
const Quat = core.math.Quat;
const Vec3 = core.math.Vec3;

pub const transform_name = "foundry:transform";
pub const parent_name = "foundry:parent";
pub const world_transform_name = "foundry:world_transform";

/// A local pose: `core.Transform`'s layout under its engine name. Saved and authorable.
///
/// A struct of its own only because the component's name is a declaration on the type, and
/// `core` cannot carry `scene`'s names. `fromCore` and `toCore` are bit casts, and the
/// layout check below keeps them honest.
pub const Transform = extern struct {
    pub const component = transform_name;

    /// Metres, in the parent's frame.
    translation: Vec3 = Vec3.zero,
    /// A unit quaternion, `(x, y, z, w)` (ADR-0048).
    rotation: Quat = Quat.identity,
    /// Along the rotated axes. Zero collapses an axis and a negative value reflects it; both
    /// are legal to author (`core.Transform.isValid`).
    scale: Vec3 = Vec3.one,

    pub fn fromCore(t: core.math.Transform) Transform {
        return @bitCast(t);
    }

    pub fn toCore(t: Transform) core.math.Transform {
        return @bitCast(t);
    }

    pub fn isValid(t: Transform) bool {
        return t.toCore().isValid();
    }
};

comptime {
    const C = core.math.Transform;
    std.debug.assert(@sizeOf(Transform) == @sizeOf(C));
    std.debug.assert(@alignOf(Transform) == @alignOf(C));
    for (.{ "translation", "rotation", "scale" }) |field| {
        std.debug.assert(@offsetOf(Transform, field) == @offsetOf(C, field));
    }
}

/// The entity this one's pose is relative to. Saved as the handle's packing, which a save
/// preserves exactly (`entity-storage.md` §9); never authored (§3.3), because a number in a
/// template would name whatever entity happened to hold that slot.
pub const Parent = extern struct {
    pub const component = parent_name;

    entity: Entity = .none,
};

/// The derived world pose, column-major. Written only by propagation (Step 2), never saved,
/// never authored: it has no serializer and no deserializer, so its schema has no fields and
/// a save or an inspector leaves it out. `hierarchy.worldTransform` reads it (§4.3).
pub const WorldTransform = extern struct {
    matrix: Mat4 = Mat4.identity,
};

/// The three types, as one world registered them.
pub const Types = struct {
    transform: ComponentType,
    parent: ComponentType,
    world_transform: ComponentType,
};

/// `foundry:transform`'s registration: derived, with a deserializer that refuses a pose
/// `isValid` refuses. A template and a save both arrive through it, and both are untrusted.
pub fn transformInfo() ComponentTypeInfo {
    var info = derive.componentType(Transform);
    info.deserialize = &deserializeTransform;
    return info;
}

/// The schema content is compiled against. The same value the world registers, so the two
/// can never disagree about a field or a default.
pub const transform_schema: data.Schema = derive.componentType(Transform).schema;

fn deserializeTransform(ctx: ?*anyopaque, fields: data.fpk.Fields, out: [*]u8) component.DeserializeError!void {
    const derived = comptime derive.componentType(Transform).deserialize.?;
    try derived(ctx, fields, out);
    const value: *const Transform = @ptrCast(@alignCast(out));
    if (!value.isValid()) return error.ValueOutOfRange;
}

pub fn parentInfo() ComponentTypeInfo {
    return derive.componentType(Parent);
}

pub fn worldTransformInfo() ComponentTypeInfo {
    return .{
        .schema = .{
            .id = data.SchemaId.fromStringUnchecked(world_transform_name),
            .version = 1,
            .fields = &.{},
        },
        .name = world_transform_name,
        .size = @sizeOf(WorldTransform),
        .alignment = @alignOf(WorldTransform),
        .construct = &constructWorldTransform,
    };
}

fn constructWorldTransform(_: ?*anyopaque, out: [*]u8) void {
    const value: *WorldTransform = @ptrCast(@alignCast(out));
    value.* = .{};
}

// -- per-world state -------------------------------------------------------------------

/// What a world with the hierarchy keeps: its three types, and which repairs it has already
/// reported, so a broken save is logged once rather than every tick (§6).
pub const State = struct {
    types: Types,
    reported: std.AutoHashMapUnmanaged(u64, Reported) = .empty,
    /// Bumped by every propagation, to find reports that no longer apply.
    run: u64 = 0,
    /// How many repairs have been logged, ever. What a test reads to prove "once".
    reports: u64 = 0,
    /// Scratch for walking descendants, one entry per `foundry:parent`: a depth for each,
    /// by the parent store's dense index, and the entities found. Reserved as each parent is
    /// added, so the cascade in `World.destroy`, which cannot fail, never allocates.
    walk: std.ArrayList(u32) = .empty,
    found: std.ArrayList(Descendant) = .empty,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.reported.deinit(gpa);
        self.walk.deinit(gpa);
        self.found.deinit(gpa);
    }

    /// Room to walk `parents` parent components.
    pub fn reserve(self: *State, gpa: Allocator, parents: usize) Allocator.Error!void {
        try self.walk.ensureTotalCapacity(gpa, parents);
        try self.found.ensureTotalCapacity(gpa, parents);
    }
};

/// What §6 had to repair about one entity.
pub const Repair = enum { orphan, cycle, too_deep, invalid };

const Reported = struct {
    repair: Repair,
    /// The raw parent and a hash of the raw local pose when it was reported. A change to
    /// either is a new situation, and is reported again.
    parent: u64,
    transform: u64,
    run: u64,
};

// -- propagation (§4) ----------------------------------------------------------------

pub const PropagationStats = struct {
    /// Entities with `foundry:transform`.
    entities: u32 = 0,
    /// Of those, the ones propagated from the identity: no parent, or one §6 set aside.
    roots: u32 = 0,
    /// The deepest effective depth, in edges.
    max_depth: u32 = 0,
    orphans: u32 = 0,
    cycles: u32 = 0,
    too_deep: u32 = 0,
    invalid: u32 = 0,
};

pub const propagation_system_name = "foundry:systems.propagate_transforms";

/// The propagation as a system, for the host to register after the systems that write
/// transforms and before anything that reads world transforms (§4.1). Registration order is
/// the order systems run in, so where the host registers it is where it runs.
pub fn system() system_mod.System {
    return .{
        .id = core.ContentId.fromString(propagation_system_name),
        .name = propagation_system_name,
        .update = &runSystem,
    };
}

fn runSystem(_: ?*anyopaque, world: *World, _: system_mod.Tick) void {
    _ = propagate(world) catch |err| {
        // Last tick's world transforms stay, which §4.3 already promises between runs.
        log.err("transform propagation failed ({t}); world transforms are last tick's", .{err});
    };
}

const unset = std.math.maxInt(u32);

/// Writes every `foundry:world_transform` from the local poses (§4.2). A world without the
/// hierarchy has nothing to do.
///
/// Ordered by effective depth, then by slot index, so every parent is computed before its
/// children and the result depends on the world's contents alone (I9). Each matrix is
/// `W_parent · local`, and a root's is its local pose, so it is bit-identical however the
/// entities came to be. It never decomposes: a sheared world is carried down exactly.
pub fn propagate(world: *World) Allocator.Error!PropagationStats {
    const state = if (world.hierarchy) |*s| s else return .{};
    const gpa = world.gpa;
    const types = state.types;
    state.run +%= 1;

    const slots = world.entities.capacity();
    const depth = try gpa.alloc(u32, slots);
    defer gpa.free(depth);
    const effective = try gpa.alloc(u32, slots);
    defer gpa.free(effective);
    const on_path = try gpa.alloc(bool, slots);
    defer gpa.free(on_path);
    const handles = try gpa.alloc(Entity, slots);
    defer gpa.free(handles);
    const matrices = try gpa.alloc(Mat4, slots);
    defer gpa.free(matrices);
    @memset(depth, unset);
    @memset(effective, unset);
    @memset(on_path, false);

    var order: std.ArrayList(Entity) = .empty;
    defer order.deinit(gpa);
    var path: std.ArrayList(Entity) = .empty;
    defer path.deinit(gpa);
    var repairs: std.ArrayList(Found) = .empty;
    defer repairs.deinit(gpa);

    var stats: PropagationStats = .{};
    const transforms = &world.stores.items[types.transform.index];
    try order.ensureTotalCapacity(gpa, transforms.count());
    for (0..transforms.count()) |dense| {
        const entity = transforms.ownerAt(@intCast(dense));
        order.appendAssumeCapacity(entity);
        handles[entity.index] = entity;
    }
    stats.entities = @intCast(order.items.len);

    // 1. Effective parents and depths, each entity walked once.
    for (order.items) |start| {
        if (depth[start.index] != unset) continue;
        path.clearRetainingCapacity();
        var current = start;
        // Where the walk stopped: at a root (`anchor` null), or at an entity whose depth is
        // already known.
        var anchor: ?Entity = null;
        while (true) {
            try path.append(gpa, current);
            on_path[current.index] = true;
            switch (linkOf(world, types, current)) {
                .root => break,
                .orphan => {
                    try repairs.append(gpa, .{ .entity = current, .repair = .orphan });
                    break;
                },
                .parent => |parent| {
                    if (depth[parent.index] != unset) {
                        anchor = parent;
                        break;
                    }
                    if (on_path[parent.index]) {
                        // A cycle: `parent` and everything after it on the path. Every entity
                        // on it is a root; the entries before it hang off the cycle.
                        var at: usize = 0;
                        while (!path.items[at].eql(parent)) at += 1;
                        for (path.items[at..]) |member| {
                            depth[member.index] = 0;
                            on_path[member.index] = false;
                            try repairs.append(gpa, .{ .entity = member, .repair = .cycle });
                        }
                        path.shrinkRetainingCapacity(at);
                        anchor = parent;
                        break;
                    }
                    current = parent;
                },
            }
        }
        // Unwind from the top: each entry's parent is the one after it, or the anchor.
        var i = path.items.len;
        while (i > 0) {
            i -= 1;
            const entity = path.items[i];
            on_path[entity.index] = false;
            const parent: ?Entity = if (i + 1 < path.items.len) path.items[i + 1] else anchor;
            if (parent) |p| {
                const d = depth[p.index] + 1;
                if (d > depthLimit(world)) {
                    depth[entity.index] = 0;
                    try repairs.append(gpa, .{ .entity = entity, .repair = .too_deep });
                } else {
                    depth[entity.index] = d;
                    effective[entity.index] = p.index;
                }
            } else {
                depth[entity.index] = 0;
            }
        }
    }

    // 2. Parents first, then by slot index: a total order on the world's contents.
    std.sort.pdq(Entity, order.items, depth, struct {
        fn less(d: []const u32, a: Entity, b: Entity) bool {
            if (d[a.index] != d[b.index]) return d[a.index] < d[b.index];
            return a.index < b.index;
        }
    }.less);

    // 3. Every transform gets a world transform, added already the identity, so none is ever
    // garbage. Added before any is written, because adding can move the others' bytes.
    for (order.items) |entity| {
        if (!world.hasComponent(entity, types.world_transform)) {
            _ = world.addComponent(entity, types.world_transform, null) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable, // live, registered, and checked absent just now
            };
        }
    }

    // 4. Compute and write, top down.
    for (order.items) |entity| {
        const local = transformOf(world, types, entity).?;
        const slot: *WorldTransform = @ptrCast(@alignCast(world.getComponent(entity, types.world_transform).?.ptr));
        const parent_index = effective[entity.index];
        if (!local.isValid()) {
            // A NaN from a buggy mod freezes its object rather than teleporting it (§6).
            try repairs.append(gpa, .{ .entity = entity, .repair = .invalid });
        } else {
            slot.matrix = compose(if (parent_index == unset) null else matrices[parent_index], local);
        }
        matrices[entity.index] = slot.matrix;
        if (parent_index == unset) stats.roots += 1;
        stats.max_depth = @max(stats.max_depth, depth[entity.index]);
    }

    // 5. A world transform without a transform means nothing, and is removed.
    const worlds = &world.stores.items[types.world_transform.index];
    var stale: std.ArrayList(Entity) = .empty;
    defer stale.deinit(gpa);
    for (0..worlds.count()) |dense| {
        const owner = worlds.ownerAt(@intCast(dense));
        if (!world.hasComponent(owner, types.transform)) try stale.append(gpa, owner);
    }
    for (stale.items) |owner| _ = world.removeComponent(owner, types.world_transform);

    for (repairs.items) |found| switch (found.repair) {
        .orphan => stats.orphans += 1,
        .cycle => stats.cycles += 1,
        .too_deep => stats.too_deep += 1,
        .invalid => stats.invalid += 1,
    };
    try report(world, state, repairs.items);
    return stats;
}

const Found = struct { entity: Entity, repair: Repair };

/// Logs each repair the first time it is found, and again only once its parent or local pose
/// has changed; forgets the ones that no longer apply.
fn report(world: *World, state: *State, found: []const Found) Allocator.Error!void {
    const gpa = world.gpa;
    for (found) |f| {
        const key = f.entity.bits();
        const now: Reported = .{
            .repair = f.repair,
            .parent = rawParent(world, state.types, f.entity).bits(),
            .transform = std.hash.Wyhash.hash(0, world.readComponent(f.entity, state.types.transform) orelse &.{}),
            .run = state.run,
        };
        const entry = try state.reported.getOrPut(gpa, key);
        const known = entry.found_existing and entry.value_ptr.repair == now.repair and
            entry.value_ptr.parent == now.parent and entry.value_ptr.transform == now.transform;
        entry.value_ptr.* = now;
        if (known) continue;
        state.reports += 1;
        switch (f.repair) {
            .orphan => log.warn("entity #{d}.{d}: its parent is not live; propagated as a root", .{ f.entity.index, f.entity.generation }),
            .cycle => log.warn("entity #{d}.{d}: its parent chain is a cycle; propagated as a root", .{ f.entity.index, f.entity.generation }),
            .too_deep => log.warn("entity #{d}.{d}: deeper than {d} edges; propagated as a root", .{ f.entity.index, f.entity.generation, depthLimit(world) }),
            .invalid => log.warn("entity #{d}.{d}: its foundry:transform is not a pose; its world transform is left as it was", .{ f.entity.index, f.entity.generation }),
        }
    }
    var it = state.reported.iterator();
    var gone: std.ArrayList(u64) = .empty;
    defer gone.deinit(gpa);
    while (it.next()) |entry| {
        if (entry.value_ptr.run != state.run) try gone.append(gpa, entry.key_ptr.*);
    }
    for (gone.items) |key| _ = state.reported.remove(key);
}

/// A child's world matrix from its parent's. A root's is its local pose, unmultiplied, so
/// the propagation and `worldOf` agree to the bit.
fn compose(parent: ?Mat4, local: Transform) Mat4 {
    const m = local.toCore().toMat4();
    return if (parent) |p| Mat4.mul(p, m) else m;
}

/// One step up a chain, under §6's rules.
const Link = union(enum) {
    /// No parent, or a parent without a transform, which contributes the identity.
    root,
    /// A parent that is not live.
    orphan,
    parent: Entity,
};

fn linkOf(world: *const World, types: Types, entity: Entity) Link {
    const parent = rawParent(world, types, entity);
    if (parent.isNone()) return .root;
    if (!world.contains(parent)) return .orphan;
    if (!world.hasComponent(parent, types.transform)) return .root;
    return .{ .parent = parent };
}

/// The parent as stored, whatever it names.
fn rawParent(world: *const World, types: Types, entity: Entity) Entity {
    const bytes = world.readComponent(entity, types.parent) orelse return .none;
    return std.mem.bytesToValue(Parent, bytes).entity;
}

fn transformOf(world: *const World, types: Types, entity: Entity) ?Transform {
    const bytes = world.readComponent(entity, types.transform) orelse return null;
    return std.mem.bytesToValue(Transform, bytes);
}

// -- reading a pose (§4.3) -------------------------------------------------------------

/// The last propagation's world matrix. Between propagations it is last tick's (ADR-0050).
/// Null for a stale entity, one without a transform, or one never propagated.
pub fn worldTransform(world: *const World, entity: Entity) ?Mat4 {
    const state = world.hierarchy orelse return null;
    const bytes = world.readComponent(entity, state.types.world_transform) orelse return null;
    return std.mem.bytesToValue(WorldTransform, bytes).matrix;
}

/// The parent as stored, if it is live. A stale parent is null here, and a root to the
/// propagation.
pub fn parentOf(world: *const World, entity: Entity) ?Entity {
    const state = world.hierarchy orelse return null;
    if (!world.contains(entity)) return null;
    const parent = rawParent(world, state.types, entity);
    if (parent.isNone() or !world.contains(parent)) return null;
    return parent;
}

/// The effective depth, under §6's rules, as the next propagation will see it.
pub fn depthOf(world: *const World, entity: Entity) ?u32 {
    var buffer: [chain_capacity]Entity = undefined;
    const chain = effectiveChain(world, entity, &buffer) orelse return null;
    return @intCast(chain.len - 1);
}

/// The world matrix computed now, from the chain as it stands, under the same rules the
/// propagation follows. Writes nothing. An entity with an invalid local pose contributes its
/// stored world transform, as the propagation would; so this equals what the next
/// propagation writes.
pub fn worldOf(world: *const World, entity: Entity) ?Mat4 {
    const state = world.hierarchy orelse return null;
    var buffer: [chain_capacity]Entity = undefined;
    const chain = effectiveChain(world, entity, &buffer) orelse return null;
    var matrix: ?Mat4 = null;
    var i = chain.len;
    while (i > 0) {
        i -= 1;
        const link = chain[i];
        const local = transformOf(world, state.types, link).?;
        matrix = if (local.isValid())
            compose(matrix, local)
        else
            worldTransform(world, link) orelse Mat4.identity;
    }
    return matrix;
}

/// A cut chain is at most the limit plus one long; the walk above the cut needs no storage,
/// only its length.
const chain_capacity = max_depth_limit + 1;

/// The deepest limit honoured, whatever `Limits` says: `worldOf` reads without allocating, so
/// its chain has a fixed bound, and the propagation must cut at the same depth to agree.
pub const max_depth_limit = 256;

fn depthLimit(world: *const World) u32 {
    return @min(world.limits.max_hierarchy_depth, max_depth_limit);
}

/// `entity` and its effective ancestors, nearest first, ending at its effective root. Null
/// for an entity without a transform. The walk up is bounded: a chain longer than the entity
/// count must be a cycle, and `chain_capacity` holds any cut chain.
fn effectiveChain(world: *const World, entity: Entity, buffer: *[chain_capacity]Entity) ?[]const Entity {
    const state = world.hierarchy orelse return null;
    const types = state.types;
    if (!world.hasComponent(entity, types.transform)) return null;
    const limit = depthLimit(world);

    // First find how far above `entity` its chain goes before it stops or repeats, counting
    // with Brent's cycle detection so no storage grows with the chain.
    var length: u32 = 1; // entities on the chain from `entity` to its top, inclusive
    var top = entity;
    var cyclic = false;
    {
        var power: u32 = 1;
        var lambda: u32 = 1;
        var tortoise = entity;
        var hare = entity;
        while (true) {
            const next = switch (linkOf(world, types, hare)) {
                .root, .orphan => break,
                .parent => |p| p,
            };
            hare = next;
            length += 1;
            top = hare;
            if (hare.eql(tortoise)) {
                cyclic = true;
                break;
            }
            if (power == lambda) {
                tortoise = hare;
                power *= 2;
                lambda = 0;
            }
            lambda += 1;
        }
    }

    // On a cycle, the chain ends at the first entity of the cycle reached from `entity`.
    if (cyclic) {
        length = cycleEntry(world, types, entity);
    }

    // Depths are counted from the top down, and a chain deeper than the limit is cut: the
    // entity past it becomes a root. So `entity`'s effective chain is the part below its
    // last cut, which is `(length - 1) mod (limit + 1)` edges long.
    const edges = (length - 1) % (limit + 1);
    var current = entity;
    buffer[0] = current;
    for (1..edges + 1) |i| {
        current = switch (linkOf(world, types, current)) {
            .parent => |p| p,
            else => unreachable, // the walk above found at least this many
        };
        buffer[i] = current;
    }
    return buffer[0 .. edges + 1];
}

/// How many entities are on the chain from `entity` up to and including the first one on its
/// cycle. `entity` itself counts as one; a member of the cycle answers one.
fn cycleEntry(world: *const World, types: Types, entity: Entity) u32 {
    // Walk `entity` up until it lands on an entity from which the walk returns to itself.
    var steps: u32 = 1;
    var current = entity;
    while (!onCycle(world, types, current)) {
        current = linkOf(world, types, current).parent;
        steps += 1;
    }
    return steps;
}

fn onCycle(world: *const World, types: Types, entity: Entity) bool {
    var current = entity;
    var hops: u32 = 0;
    const bound = world.entityCount();
    while (hops <= bound) : (hops += 1) {
        current = switch (linkOf(world, types, current)) {
            .parent => |p| p,
            else => return false,
        };
        if (current.eql(entity)) return true;
    }
    return false;
}

// -- descendants (§5.4) ----------------------------------------------------------------

/// An entity below another, and how many stored `foundry:parent` links separate them.
pub const Descendant = struct { entity: Entity, depth: u32 };

const walk_unknown = std.math.maxInt(u32);
const walk_outside = std.math.maxInt(u32) - 1;

/// Every entity whose stored `foundry:parent` links reach `root`, deepest first and then by
/// ascending slot index (I9): the order the cascade destroys them in. Borrowed from the
/// world's scratch until the next call; allocates nothing.
///
/// **Stored links, not effective ones.** A parent without a transform contributes the
/// identity to the propagation (§6), but it is still somebody's parent, and destroying it
/// takes its children. A stale link reaches nothing. A cycle through `root` makes every other
/// member a descendant; a cycle elsewhere is walked once and left alone.
pub fn descendants(world: *const World, state: *State, root: Entity) []const Descendant {
    const types = state.types;
    const parents = &world.stores.items[types.parent.index];
    const count = parents.count();
    std.debug.assert(state.walk.capacity >= count and state.found.capacity >= count);
    const depth = state.walk.allocatedSlice()[0..count];
    @memset(depth, walk_unknown);
    // A walk longer than every live entity has gone round a cycle that `root` is not on.
    const bound = world.entityCount();

    for (0..count) |start| {
        if (depth[start] != walk_unknown) continue;
        // Up, until the answer is known: `root` itself, something already answered, or a
        // chain that ends or loops elsewhere.
        var current = parents.ownerAt(@intCast(start));
        var steps: u32 = 0;
        const answer: u32 = while (true) : (steps += 1) {
            if (current.eql(root)) break steps;
            const dense = parents.denseIndex(current) orelse break walk_outside;
            const known = depth[dense];
            if (known != walk_unknown) break if (known == walk_outside) walk_outside else known + steps;
            if (steps > bound) break walk_outside;
            const up = rawParent(world, types, current);
            if (!world.contains(up)) break walk_outside;
            current = up;
        };
        // Stopped where it started: `root` itself (zero, and not its own descendant), or a
        // stale link (outside). The walk below writes nothing for it.
        if (steps == 0) depth[start] = answer;
        // And again, writing the answer down for everything the first walk passed.
        current = parents.ownerAt(@intCast(start));
        for (0..steps) |i| {
            depth[parents.denseIndex(current).?] = if (answer == walk_outside) walk_outside else answer - @as(u32, @intCast(i));
            current = rawParent(world, types, current);
        }
    }

    state.found.clearRetainingCapacity();
    for (depth, 0..) |d, dense| {
        if (d == walk_outside or d == 0) continue;
        state.found.appendAssumeCapacity(.{ .entity = parents.ownerAt(@intCast(dense)), .depth = d });
    }
    std.sort.pdq(Descendant, state.found.items, {}, struct {
        fn less(_: void, a: Descendant, b: Descendant) bool {
            if (a.depth != b.depth) return a.depth > b.depth;
            return a.entity.index < b.entity.index;
        }
    }.less);
    return state.found.items;
}

// -- re-parenting (§5) -------------------------------------------------------------------

/// Each is the step of `docs/design/3d.md` §7.1 that refused (ADR-0050).
pub const ReparentError = error{
    /// The child is not live or has no `foundry:transform`; or the parent is not live, or,
    /// for keep-world, has no transform. A world without the hierarchy has no transforms.
    NoSuchEntity,
    /// The parent is the child, or one of its descendants.
    WouldCycle,
    /// The child's subtree would reach deeper than the limit.
    TooDeep,
    /// Keep-world: the new parent's world matrix cannot be inverted, within the tolerance.
    SingularParent,
    /// Keep-world: the child's world pose is not a `Transform` under the new parent, which is
    /// shear, a collapsed axis, or a value that is not finite.
    NotRepresentable,
    /// Reserving the parent component, before anything was written.
    OutOfMemory,
};

/// Re-parents `child`, or detaches it when `parent` is null, **keeping its local pose**: it
/// moves with its new parent from the next propagation (§5.1). It never decomposes, so any
/// valid parent is accepted, a sheared chain included. A parent without a transform is
/// accepted, and contributes the identity.
pub fn setParent(world: *World, child: Entity, parent: ?Entity) ReparentError!void {
    const state = try checkReparent(world, child, parent, false);
    commit(world, state, child, parent, null);
}

/// Re-parents `child`, or detaches it when `parent` is null, **keeping its world pose**
/// (`3d.md` §7.1, step for step). Both world matrices are computed fresh, never read from a
/// possibly stale `foundry:world_transform`; the new local pose is `P⁻¹ · W`, decomposed
/// exactly or refused. On success the parent and transform are written together, and the
/// world transform is left for the next propagation. On refusal nothing is written.
pub fn setParentKeepWorld(world: *World, child: Entity, parent: ?Entity) ReparentError!void {
    // 1. Validate.
    const state = try checkReparent(world, child, parent, true);
    // 2. Both world matrices, fresh, and finite.
    const w = worldOf(world, child).?;
    const p = if (parent) |e| worldOf(world, e).? else Mat4.identity;
    if (!finite(w)) return error.NotRepresentable;
    if (!finite(p)) return error.SingularParent;
    // 3. Invert the parent, refusing one too close to singular for its size.
    var norm: f32 = 0;
    for (0..3) |c| for (0..3) |r| {
        norm = @max(norm, @abs(p.cols[c][r]));
    };
    const scale = @max(@as(f32, 1), norm);
    const det = Mat4.determinant(p);
    if (!(@abs(det) >= core.math.Transform.determinant_epsilon * scale * scale * scale)) return error.SingularParent;
    const inverse = Mat4.inverse(p) orelse return error.SingularParent;
    // 4 and 5. Decompose `L = P⁻¹ · W`, exactly or not at all. Both factors are affine, so
    // `L` is; its last row is set so, rather than left to the rounding of `1 / det · det`.
    var l = Mat4.mul(inverse, w);
    l.cols[0][3] = 0;
    l.cols[1][3] = 0;
    l.cols[2][3] = 0;
    l.cols[3][3] = 1;
    const local = core.math.Transform.fromMat4Exact(l) catch return error.NotRepresentable;
    // 6. Commit.
    commit(world, state, child, parent, Transform.fromCore(local));
}

fn finite(m: Mat4) bool {
    for (m.cols) |column| for (column) |value| {
        if (!std.math.isFinite(value)) return false;
    };
    return true;
}

/// §5.1's checks, shared by both calls, and the reservation that makes the commit
/// infallible. Writes no component.
fn checkReparent(world: *World, child: Entity, parent: ?Entity, keep_world: bool) ReparentError!*State {
    const state = if (world.hierarchy) |*s| s else return error.NoSuchEntity;
    const types = state.types;
    if (!world.hasComponent(child, types.transform)) return error.NoSuchEntity;
    const p = parent orelse return state;
    if (!world.contains(p)) return error.NoSuchEntity;
    const parent_has_transform = world.hasComponent(p, types.transform);
    if (keep_world and !parent_has_transform) return error.NoSuchEntity;
    if (p.eql(child)) return error.WouldCycle;

    // The child's subtree, by the cascade's walk: the parent must not be in it, and it must
    // fit below the parent. A parent without a transform starts a new chain (§6).
    var deepest: u32 = 0;
    for (descendants(world, state, child)) |d| {
        if (d.entity.eql(p)) return error.WouldCycle;
        deepest = @max(deepest, d.depth);
    }
    const at: u32 = if (parent_has_transform) depthOf(world, p).? + 1 else 0;
    if (at + deepest > depthLimit(world)) return error.TooDeep;

    if (!world.hasComponent(child, types.parent)) {
        try state.reserve(world.gpa, world.stores.items[types.parent.index].count() + 1);
        try world.stores.items[types.parent.index].reserve(world.gpa, child);
    }
    return state;
}

/// Writes the parent, and the local pose if there is one, after every check has passed.
/// Cannot fail: the parent component exists, or was reserved by `checkReparent`.
fn commit(world: *World, state: *State, child: Entity, parent: ?Entity, local: ?Transform) void {
    const types = state.types;
    if (parent) |p| {
        const value: Parent = .{ .entity = p };
        if (world.getComponent(child, types.parent)) |bytes| {
            @memcpy(bytes, std.mem.asBytes(&value));
        } else {
            _ = world.addComponent(child, types.parent, std.mem.asBytes(&value)) catch unreachable; // reserved, live, absent
        }
    } else {
        _ = world.removeComponent(child, types.parent);
    }
    if (local) |t| {
        @memcpy(world.getComponent(child, types.transform).?, std.mem.asBytes(&t));
    }
}

// -- tests ---------------------------------------------------------------------------
//
// Registration through `World.enableHierarchy` and the content rules are tested in
// `world.zig`, beside the calls they exercise.

const testing = std.testing;

test "the transform's schema is its public layout, with the identity as defaults" {
    const schema = transform_schema;
    try testing.expectEqual(@as(u32, 1), schema.version);
    try testing.expectEqual(@as(usize, 3), schema.fields.len);
    try testing.expectEqualStrings("translation", schema.fields[0].name);
    try testing.expectEqualStrings("rotation", schema.fields[1].name);
    try testing.expectEqualStrings("scale", schema.fields[2].name);
    const rotation = schema.fields[1].type.nested;
    try testing.expectEqual(@as(usize, 4), rotation.len);
    try testing.expectEqualStrings("w", rotation[3].name);
    try testing.expectEqual(@as(usize, @sizeOf(core.math.Transform)), transformInfo().size);
}

test "a parent is one entity, and a world transform has nothing to save" {
    const parent = parentInfo();
    try testing.expectEqual(@as(usize, 1), parent.schema.fields.len);
    try testing.expectEqualStrings("entity", parent.schema.fields[0].name);
    try testing.expect(parent.serialize != null and parent.deserialize != null);

    const world = worldTransformInfo();
    try testing.expectEqual(@as(usize, 0), world.schema.fields.len);
    try testing.expect(world.serialize == null and world.deserialize == null);
    try testing.expectEqual(@as(u32, 64), world.size);
}

// -- propagation (§4, §6) ------------------------------------------------------------

const Fx = struct {
    schemas: data.Registry,
    world: World,
    types: Types,

    fn init(gpa: Allocator, limits: @import("limits.zig").Limits) !*Fx {
        const f = try gpa.create(Fx);
        f.schemas = .init(gpa, .default);
        f.world = .init(gpa, &f.schemas, limits);
        f.types = try f.world.enableHierarchy();
        return f;
    }

    fn deinit(f: *Fx, gpa: Allocator) void {
        f.world.deinit();
        f.schemas.deinit(gpa);
        gpa.destroy(f);
    }

    /// An entity with a local pose and, if given, a parent, written as raw bytes: the path a
    /// native mod or a save takes, which no re-parenting call checks.
    fn node(f: *Fx, local: core.math.Transform, parent: ?Entity) !Entity {
        const e = try f.world.create();
        const t = Transform.fromCore(local);
        _ = try f.world.addComponent(e, f.types.transform, std.mem.asBytes(&t));
        if (parent) |p| try f.setRawParent(e, p);
        return e;
    }

    fn setRawParent(f: *Fx, e: Entity, p: Entity) !void {
        const value: Parent = .{ .entity = p };
        if (f.world.getComponent(e, f.types.parent)) |bytes| {
            @memcpy(bytes, std.mem.asBytes(&value));
        } else {
            _ = try f.world.addComponent(e, f.types.parent, std.mem.asBytes(&value));
        }
    }
};

fn pose(t: [3]f32, axis: [3]f32, angle: f32, s: [3]f32) core.math.Transform {
    return .{
        .translation = .init(t[0], t[1], t[2]),
        .rotation = Quat.fromAxisAngle(Vec3.init(axis[0], axis[1], axis[2]).normalize(), angle),
        .scale = .init(s[0], s[1], s[2]),
    };
}

/// A small tree with a sheared branch: 0 is a root; 1 and 2 are its children; 3 is 1's; 4 is
/// 3's, under a non-uniformly scaled parent and rotated against it.
const tree = [_]struct { local: core.math.Transform, parent: ?usize }{
    .{ .local = pose(.{ 1, 2, 3 }, .{ 0, 1, 0 }, 0.7, .{ 1, 1, 1 }), .parent = null },
    .{ .local = pose(.{ 0.5, 0, 0 }, .{ 1, 0, 0 }, 0.3, .{ 2, 1, 1 }), .parent = 0 },
    .{ .local = pose(.{ 0, 1, 0 }, .{ 0, 0, 1 }, -1.1, .{ 1, 1, 1 }), .parent = 0 },
    .{ .local = pose(.{ 0, 0, 1 }, .{ 0, 0, 1 }, std.math.pi / 4.0, .{ 1, 3, 1 }), .parent = 1 },
    .{ .local = pose(.{ 0.2, 0.2, 0 }, .{ 1, 1, 0 }, 0.9, .{ 0.5, 0.5, 0.5 }), .parent = 3 },
};

/// Builds `tree` creating its nodes in `order`, with `padding` throwaway entities first so
/// the slot indices differ too, and returns every node's world matrix in tree order.
fn propagateTree(order: []const usize, padding: u32) ![tree.len]Mat4 {
    const gpa = testing.allocator;
    const f = try Fx.init(gpa, .default);
    defer f.deinit(gpa);
    for (0..padding) |_| _ = try f.world.create();

    var made: [tree.len]?Entity = @splat(null);
    for (order) |i| {
        made[i] = try f.node(tree[i].local, null);
    }
    for (tree, 0..) |n, i| {
        if (n.parent) |p| try f.setRawParent(made[i].?, made[p].?);
    }
    _ = try propagate(&f.world);
    var out: [tree.len]Mat4 = undefined;
    for (&out, 0..) |*m, i| m.* = worldTransform(&f.world, made[i].?).?;
    return out;
}

test "propagation is bit-identical whatever order the entities were spawned in" {
    const reference = try propagateTree(&.{ 0, 1, 2, 3, 4 }, 0);
    // Children before parents, and slot indices shifted, and interleaved.
    for ([_]struct { order: []const usize, padding: u32 }{
        .{ .order = &.{ 4, 3, 2, 1, 0 }, .padding = 0 },
        .{ .order = &.{ 2, 4, 0, 3, 1 }, .padding = 7 },
    }) |run| {
        const again = try propagateTree(run.order, run.padding);
        try testing.expectEqualSlices(u8, std.mem.asBytes(&reference), std.mem.asBytes(&again));
    }
}

test "a rotated, non-uniformly scaled chain propagates a sheared world exactly" {
    const gpa = testing.allocator;
    const f = try Fx.init(gpa, .default);
    defer f.deinit(gpa);

    // 3d.md §7.1's example: a parent scaled (2, 1, 1), a child turned 45° about Z.
    const parent_pose = pose(.{ 0, 0, 0 }, .{ 0, 0, 1 }, 0, .{ 2, 1, 1 });
    const child_pose = pose(.{ 1, 0, 0 }, .{ 0, 0, 1 }, std.math.pi / 4.0, .{ 1, 1, 1 });
    const parent = try f.node(parent_pose, null);
    const child = try f.node(child_pose, parent);
    _ = try propagate(&f.world);

    const expected = Mat4.mul(parent_pose.toMat4(), child_pose.toMat4());
    const got = worldTransform(&f.world, child).?;
    try testing.expectEqualSlices(u8, std.mem.asBytes(&expected), std.mem.asBytes(&got));
    // It is sheared: the child's axes are no longer at right angles, so no TRS holds it,
    // and the propagation carried it anyway.
    const x = Vec3.init(got.cols[0][0], got.cols[0][1], got.cols[0][2]);
    const y = Vec3.init(got.cols[1][0], got.cols[1][1], got.cols[1][2]);
    try testing.expect(@abs(Vec3.dot(x, y)) > 0.5);
    try testing.expectError(error.NotRepresentable, core.math.Transform.fromMat4Exact(got));
}

test "world transforms exist exactly where there is a transform" {
    const gpa = testing.allocator;
    const f = try Fx.init(gpa, .default);
    defer f.deinit(gpa);

    const a = try f.node(pose(.{ 1, 0, 0 }, .{ 0, 1, 0 }, 0, .{ 1, 1, 1 }), null);
    const bare = try f.world.create();
    // Before any propagation, there is none to read, never garbage.
    try testing.expect(worldTransform(&f.world, a) == null);

    const stats = try propagate(&f.world);
    try testing.expectEqual(@as(u32, 1), stats.entities);
    try testing.expectEqual(@as(u32, 1), stats.roots);
    try testing.expect(worldTransform(&f.world, a) != null);
    try testing.expect(worldTransform(&f.world, bare) == null);

    // Losing the transform loses the world transform at the next propagation.
    try testing.expect(f.world.removeComponent(a, f.types.transform));
    _ = try propagate(&f.world);
    try testing.expect(!f.world.hasComponent(a, f.types.world_transform));
}

test "worldOf is what the next propagation writes, and writes nothing itself" {
    const gpa = testing.allocator;
    const f = try Fx.init(gpa, .default);
    defer f.deinit(gpa);

    var made: [tree.len]Entity = undefined;
    for (tree, 0..) |n, i| made[i] = try f.node(n.local, if (n.parent) |p| made[p] else null);
    _ = try propagate(&f.world);

    // Move the root; the stored world transforms are now a tick old.
    const moved = Transform.fromCore(pose(.{ -4, 0, 2 }, .{ 0, 0, 1 }, 0.25, .{ 1, 2, 1 }));
    @memcpy(f.world.getComponent(made[0], f.types.transform).?, std.mem.asBytes(&moved));
    const stale = worldTransform(&f.world, made[4]).?;

    const before = f.world.mutationGeneration();
    var fresh: [tree.len]Mat4 = undefined;
    for (&fresh, made) |*m, e| m.* = worldOf(&f.world, e).?;
    try testing.expectEqual(before, f.world.mutationGeneration());
    try testing.expectEqualSlices(u8, std.mem.asBytes(&stale), std.mem.asBytes(&worldTransform(&f.world, made[4]).?));

    _ = try propagate(&f.world);
    for (fresh, made) |m, e| {
        try testing.expectEqualSlices(u8, std.mem.asBytes(&m), std.mem.asBytes(&worldTransform(&f.world, e).?));
    }
    try testing.expectEqual(@as(?u32, 0), depthOf(&f.world, made[0]));
    try testing.expectEqual(@as(?u32, 3), depthOf(&f.world, made[4]));
    try testing.expect(parentOf(&f.world, made[4]).?.eql(made[3]));
    try testing.expect(parentOf(&f.world, made[0]) == null);
}

test "the propagation system runs where the host registered it" {
    const gpa = testing.allocator;
    const f = try Fx.init(gpa, .default);
    defer f.deinit(gpa);
    const a = try f.node(pose(.{ 3, 0, 0 }, .{ 0, 1, 0 }, 0, .{ 1, 1, 1 }), null);
    _ = try f.world.registerSystem(system());
    f.world.update(.{ .tick = 1, .delta = .fromMillis(16) });
    try testing.expectEqual(@as(f32, 3), worldTransform(&f.world, a).?.cols[3][0]);
}

test "a hostile save loads, and propagates by the repair table, each repair logged once" {
    const gpa = testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    const shape = struct { gone_child: Entity, a: Entity, b: Entity, tail: Entity, deep: Entity };
    var saved: shape = undefined;
    {
        const f = try Fx.init(gpa, .default);
        defer f.deinit(gpa);
        const unit = core.math.Transform.identity;
        // A parent that is gone. Written raw after it went, since destroying a parent now
        // takes its children with it.
        const gone = try f.node(unit, null);
        _ = f.world.destroy(gone);
        saved.gone_child = try f.node(pose(.{ 1, 0, 0 }, .{ 0, 1, 0 }, 0, .{ 1, 1, 1 }), gone);
        // A two-entity cycle, with a tail hanging off it.
        saved.a = try f.node(pose(.{ 0, 1, 0 }, .{ 0, 1, 0 }, 0, .{ 1, 1, 1 }), null);
        saved.b = try f.node(pose(.{ 0, 2, 0 }, .{ 0, 1, 0 }, 0, .{ 1, 1, 1 }), saved.a);
        try f.setRawParent(saved.a, saved.b);
        saved.tail = try f.node(pose(.{ 0, 0, 5 }, .{ 0, 1, 0 }, 0, .{ 1, 1, 1 }), saved.a);
        // A chain of 66: depths 0 to 64, and the 66th past the limit.
        var link = try f.node(unit, null);
        for (0..65) |_| link = try f.node(pose(.{ 0, 0.1, 0 }, .{ 0, 1, 0 }, 0, .{ 1, 1, 1 }), link);
        saved.deep = link;
        try f.world.save(&bytes);
    }

    const f = try Fx.init(gpa, .default);
    defer f.deinit(gpa);
    _ = try f.world.load(bytes.items, .default);

    var stats: PropagationStats = undefined;
    for (0..10) |_| stats = try propagate(&f.world);
    try testing.expectEqual(@as(u32, 1), stats.orphans);
    try testing.expectEqual(@as(u32, 2), stats.cycles);
    try testing.expectEqual(@as(u32, 1), stats.too_deep);
    try testing.expectEqual(@as(u32, 0), stats.invalid);
    try testing.expectEqual(@as(u32, 64), stats.max_depth);
    // Reported once each across ten runs, not ten times.
    try testing.expectEqual(@as(u64, 4), f.world.hierarchy.?.reports);

    // Each repair is the documented one.
    try testing.expectEqual(@as(f32, 1), worldTransform(&f.world, saved.gone_child).?.cols[3][0]);
    try testing.expectEqual(@as(f32, 1), worldTransform(&f.world, saved.a).?.cols[3][1]);
    try testing.expectEqual(@as(f32, 2), worldTransform(&f.world, saved.b).?.cols[3][1]);
    try testing.expectEqual(@as(?u32, 1), depthOf(&f.world, saved.tail));
    try testing.expectEqual(@as(?u32, 0), depthOf(&f.world, saved.deep));
    // And worldOf follows the same rules.
    for ([_]Entity{ saved.gone_child, saved.a, saved.b, saved.tail, saved.deep }) |e| {
        try testing.expectEqualSlices(u8, std.mem.asBytes(&worldTransform(&f.world, e).?), std.mem.asBytes(&worldOf(&f.world, e).?));
    }

    // A changed parent is a new situation, reported again; an unchanged one is not.
    try f.setRawParent(saved.gone_child, .{ .index = 9999, .generation = 3 });
    _ = try propagate(&f.world);
    _ = try propagate(&f.world);
    try testing.expectEqual(@as(u64, 5), f.world.hierarchy.?.reports);
}

test "an invalid local pose freezes its entity, and its subtree follows the frozen pose" {
    const gpa = testing.allocator;
    const f = try Fx.init(gpa, .default);
    defer f.deinit(gpa);
    const root = try f.node(pose(.{ 2, 0, 0 }, .{ 0, 1, 0 }, 0, .{ 1, 1, 1 }), null);
    const child = try f.node(pose(.{ 0, 1, 0 }, .{ 0, 1, 0 }, 0, .{ 1, 1, 1 }), root);
    _ = try propagate(&f.world);
    const frozen = worldTransform(&f.world, root).?;

    // A native write no deserializer saw: a NaN rotation.
    const broken: *Transform = @ptrCast(@alignCast(f.world.getComponent(root, f.types.transform).?.ptr));
    broken.rotation.x = std.math.nan(f32);
    broken.translation.x = 50;
    const stats = try propagate(&f.world);
    try testing.expectEqual(@as(u32, 1), stats.invalid);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&frozen), std.mem.asBytes(&worldTransform(&f.world, root).?));
    try testing.expectEqual(@as(f32, 2), worldTransform(&f.world, child).?.cols[3][0]);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&worldTransform(&f.world, child).?), std.mem.asBytes(&worldOf(&f.world, child).?));

    // A save of it is refused whole, because the pose is validated where it enters.
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try f.world.save(&bytes);
    const g = try Fx.init(gpa, .default);
    defer g.deinit(gpa);
    try testing.expectError(error.SaveCorrupt, g.world.load(bytes.items, .default));
}

// -- re-parenting (§5) ---------------------------------------------------------------

/// Every entity's components as bytes: the save, which leaves world transforms out, and then
/// each world transform with its owner. A refusal must leave this byte-identical (§5.3).
fn snapshot(f: *Fx) ![]u8 {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try f.world.save(&out);
    const worlds = &f.world.stores.items[f.types.world_transform.index];
    for (0..worlds.count()) |dense| {
        try out.appendSlice(gpa, std.mem.asBytes(&worlds.ownerAt(@intCast(dense)).bits()));
        try out.appendSlice(gpa, worlds.at(@intCast(dense)));
    }
    try out.appendSlice(gpa, std.mem.asBytes(&f.world.mutationGeneration()));
    return out.toOwnedSlice(gpa);
}

/// The refusal named, and nothing written by it.
fn expectRefusedUnchanged(f: *Fx, expected: ReparentError, keep_world: bool, child: Entity, parent: ?Entity) !void {
    const gpa = testing.allocator;
    const before = try snapshot(f);
    defer gpa.free(before);
    const result = if (keep_world) setParentKeepWorld(&f.world, child, parent) else setParent(&f.world, child, parent);
    try testing.expectError(expected, result);
    const after = try snapshot(f);
    defer gpa.free(after);
    try testing.expectEqualSlices(u8, before, after);
}

/// Element for element, within `3d.md` §7.1's tolerance scaled to the matrix.
fn expectSamePose(expected: Mat4, got: Mat4) !void {
    var norm: f32 = 0;
    for (expected.cols) |c| for (c) |v| {
        norm = @max(norm, @abs(v));
    };
    const tolerance = core.math.Transform.representation_epsilon * @max(@as(f32, 1), norm);
    for (0..4) |c| for (0..4) |r| {
        try testing.expectApproxEqAbs(expected.cols[c][r], got.cols[c][r], tolerance);
    };
}

fn localOf(f: *Fx, e: Entity) core.math.Transform {
    return transformOf(&f.world, f.types, e).?.toCore();
}

test "keep-local re-parenting is accepted under a sheared chain, and moves with its parent" {
    const gpa = testing.allocator;
    const f = try Fx.init(gpa, .default);
    defer f.deinit(gpa);
    // 3d.md §7.1's shearing parent, with a rotated child under it: a sheared world.
    const parent_pose = pose(.{ 0, 0, 0 }, .{ 0, 0, 1 }, 0, .{ 2, 1, 1 });
    const child_pose = pose(.{ 1, 0, 0 }, .{ 0, 0, 1 }, std.math.pi / 4.0, .{ 1, 1, 1 });
    const shearing = try f.node(parent_pose, null);
    const sheared = try f.node(child_pose, shearing);
    const mover_pose = pose(.{ 0, 3, 0 }, .{ 1, 0, 0 }, 0.4, .{ 1, 1, 1 });
    const mover = try f.node(mover_pose, null);

    try setParent(&f.world, mover, sheared);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&mover_pose), std.mem.asBytes(&localOf(f, mover)));
    try testing.expect(parentOf(&f.world, mover).?.eql(sheared));
    _ = try propagate(&f.world);
    const expected = Mat4.mul(worldTransform(&f.world, sheared).?, mover_pose.toMat4());
    try testing.expectEqualSlices(u8, std.mem.asBytes(&expected), std.mem.asBytes(&worldTransform(&f.world, mover).?));

    // Moving the parent moves it; detaching leaves the local pose as the world pose.
    try setParent(&f.world, mover, null);
    try testing.expect(parentOf(&f.world, mover) == null);
    try testing.expect(!f.world.hasComponent(mover, f.types.parent));
    _ = try propagate(&f.world);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&mover_pose.toMat4()), std.mem.asBytes(&worldTransform(&f.world, mover).?));

    // A parent without a transform is accepted, and contributes the identity.
    const bare = try f.world.create();
    try setParent(&f.world, mover, bare);
    try testing.expectEqual(@as(?u32, 0), depthOf(&f.world, mover));
}

test "keep-world re-parenting keeps the world pose under uniform and aligned scale" {
    const gpa = testing.allocator;
    const f = try Fx.init(gpa, .default);
    defer f.deinit(gpa);
    const grand = try f.node(pose(.{ 4, -1, 2 }, .{ 0, 1, 0 }, 0.6, .{ 1, 1, 1 }), null);
    const uniform = try f.node(pose(.{ 1, 2, 3 }, .{ 1, 1, 0 }, 1.2, .{ 2.5, 2.5, 2.5 }), grand);
    const aligned = try f.node(pose(.{ -2, 0, 1 }, .{ 0, 0, 1 }, 0, .{ 2, 1, 0.5 }), null);
    const child = try f.node(pose(.{ 0.5, 1, -3 }, .{ 0.3, 1, 0.2 }, 0.8, .{ 1, 2, 1 }), null);
    // Turned a quarter about X, its axes lie along the aligned parent's scaled ones.
    const square = try f.node(pose(.{ 1, 1, 1 }, .{ 1, 0, 0 }, std.math.pi / 2.0, .{ 1, 1, 3 }), null);
    _ = try propagate(&f.world);

    const before = worldTransform(&f.world, child).?;
    try setParentKeepWorld(&f.world, child, uniform);
    try testing.expect(parentOf(&f.world, child).?.eql(uniform));
    try testing.expect(localOf(f, child).isValid());
    _ = try propagate(&f.world);
    try expectSamePose(before, worldTransform(&f.world, child).?);

    const square_before = worldTransform(&f.world, square).?;
    try setParentKeepWorld(&f.world, square, aligned);
    _ = try propagate(&f.world);
    try expectSamePose(square_before, worldTransform(&f.world, square).?);

    // Detaching keeps it too, and computes both matrices fresh: moving the parent without
    // a propagation still detaches from where the parent is now.
    const moved: *Transform = @ptrCast(@alignCast(f.world.getComponent(grand, f.types.transform).?.ptr));
    moved.translation.x += 10;
    const fresh = worldOf(&f.world, child).?;
    try setParentKeepWorld(&f.world, child, null);
    try testing.expect(!f.world.hasComponent(child, f.types.parent));
    _ = try propagate(&f.world);
    try expectSamePose(fresh, worldTransform(&f.world, child).?);
}

test "keep-world re-parenting refuses shear, a singular parent, and decomposes a reflection" {
    const gpa = testing.allocator;
    const f = try Fx.init(gpa, .default);
    defer f.deinit(gpa);
    const shearing = try f.node(pose(.{ 0, 0, 0 }, .{ 0, 0, 1 }, 0, .{ 2, 1, 1 }), null);
    const turned = try f.node(pose(.{ 1, 0, 0 }, .{ 0, 0, 1 }, std.math.pi / 4.0, .{ 1, 1, 1 }), null);
    const flat = try f.node(pose(.{ 0, 5, 0 }, .{ 0, 1, 0 }, 0.3, .{ 1, 0, 1 }), null);
    const thin = try f.node(pose(.{ 0, 5, 0 }, .{ 0, 1, 0 }, 0.3, .{ 1, 1e-7, 1 }), null);
    const mirror = try f.node(pose(.{ 1, 0, 0 }, .{ 0, 1, 0 }, 0, .{ -1, 1, 1 }), null);
    const sheared = try f.node(pose(.{ 1, 0, 0 }, .{ 0, 0, 1 }, std.math.pi / 4.0, .{ 1, 1, 1 }), shearing);
    _ = try propagate(&f.world);

    // Under a shearing parent the rotated child is no TRS; a sheared child detached is none.
    try expectRefusedUnchanged(f, error.NotRepresentable, true, turned, shearing);
    try expectRefusedUnchanged(f, error.NotRepresentable, true, sheared, null);
    // Keep-local takes both, since it never decomposes.
    // A collapsed axis, and one collapsed below the tolerance, cannot be inverted.
    try expectRefusedUnchanged(f, error.SingularParent, true, turned, flat);
    try expectRefusedUnchanged(f, error.SingularParent, true, turned, thin);

    // A mirror: canonically a negative x scale over a proper rotation.
    const target = try f.node(pose(.{ 3, 0, 0 }, .{ 0, 1, 0 }, 0, .{ 1, 1, 1 }), null);
    _ = try propagate(&f.world);
    const before = worldTransform(&f.world, target).?;
    try setParentKeepWorld(&f.world, target, mirror);
    const local = localOf(f, target);
    try testing.expectApproxEqAbs(@as(f32, -1), local.scale.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), local.scale.y, 1e-6);
    try testing.expect(local.rotation.isUnit());
    try testing.expectApproxEqAbs(@as(f32, -2), local.translation.x, 1e-6);
    _ = try propagate(&f.world);
    try expectSamePose(before, worldTransform(&f.world, target).?);

    try setParent(&f.world, turned, shearing);
    try setParent(&f.world, sheared, null);
}

test "every refusal writes nothing: cycle, depth, a missing entity, and keep-world's own" {
    const gpa = testing.allocator;
    var limits: @import("limits.zig").Limits = .default;
    limits.max_hierarchy_depth = 3;
    const f = try Fx.init(gpa, limits);
    defer f.deinit(gpa);
    const unit = core.math.Transform.identity;
    // a0 - a1 - a2 - a3, at the limit; b - b1 beside it.
    const a0 = try f.node(unit, null);
    const a1 = try f.node(unit, a0);
    const a2 = try f.node(unit, a1);
    const a3 = try f.node(unit, a2);
    const b = try f.node(unit, null);
    const b1 = try f.node(unit, b);
    const bare = try f.world.create();
    const gone = try f.node(unit, null);
    _ = f.world.destroy(gone);
    _ = try propagate(&f.world);

    for ([_]bool{ false, true }) |keep_world| {
        try expectRefusedUnchanged(f, error.WouldCycle, keep_world, a1, a1);
        try expectRefusedUnchanged(f, error.WouldCycle, keep_world, a0, a3);
        try expectRefusedUnchanged(f, error.TooDeep, keep_world, b1, a3);
        // b fits below a2 on its own, and its child does not.
        try expectRefusedUnchanged(f, error.TooDeep, keep_world, b, a2);
        try expectRefusedUnchanged(f, error.NoSuchEntity, keep_world, b, gone);
        try expectRefusedUnchanged(f, error.NoSuchEntity, keep_world, gone, b);
        try expectRefusedUnchanged(f, error.NoSuchEntity, keep_world, bare, b);
    }
    // Keep-world alone needs the parent's world pose.
    try expectRefusedUnchanged(f, error.NoSuchEntity, true, b, bare);
    try setParent(&f.world, b, bare);

    // And what fits is accepted: b under a1 puts b1 at the limit exactly.
    try setParent(&f.world, b, a1);
    try testing.expectEqual(@as(?u32, 3), depthOf(&f.world, b1));

    // A world without the hierarchy has no transforms to re-parent.
    var schemas: data.Registry = .init(gpa, .default);
    defer schemas.deinit(gpa);
    var plain: World = .init(gpa, &schemas, .default);
    defer plain.deinit();
    const lone = try plain.create();
    try testing.expectError(error.NoSuchEntity, setParent(&plain, lone, null));
}

// -- the despawn cascade (§5.4) ------------------------------------------------------

/// A component whose destructor records the order entities are destroyed in.
const Tag = struct {
    pub const component = "test:tag";
    n: u32 = 0,
};

const Order = struct {
    seen: [16]u32 = undefined,
    len: usize = 0,

    fn record(ctx: ?*anyopaque, bytes: [*]u8) void {
        const self: *Order = @ptrCast(@alignCast(ctx.?));
        self.seen[self.len] = std.mem.bytesToValue(u32, bytes[0..4]);
        self.len += 1;
    }
};

fn tagged(f: *Fx, tag: ComponentType, n: u32) !Entity {
    const e = try f.node(core.math.Transform.identity, null);
    const value: Tag = .{ .n = n };
    _ = try f.world.addComponent(e, tag, std.mem.asBytes(&value));
    return e;
}

test "destroying a parent destroys its subtree, deepest first and then by slot index" {
    const gpa = testing.allocator;
    const f = try Fx.init(gpa, .default);
    defer f.deinit(gpa);
    var order: Order = .{};
    var info = derive.componentType(Tag);
    info.ctx = &order;
    info.destruct = &Order.record;
    const tag = try f.world.registerComponent(info);

    // Created so that slot order is not tree order: B0 D1 R2 C3 A4 E5, and a keeper K6.
    //   R ─ A ─ C ─ E
    //     └ B ─ D
    const b = try tagged(f, tag, 'B');
    const d = try tagged(f, tag, 'D');
    const r = try tagged(f, tag, 'R');
    const c = try tagged(f, tag, 'C');
    const a = try tagged(f, tag, 'A');
    const e = try tagged(f, tag, 'E');
    const keeper = try tagged(f, tag, 'K');
    for ([_][2]Entity{ .{ a, r }, .{ b, r }, .{ c, a }, .{ d, b }, .{ e, c }, .{ keeper, c } }) |pair| {
        try setParent(&f.world, pair[0], pair[1]);
    }
    // A child meant to survive is detached first.
    try setParent(&f.world, keeper, null);

    try testing.expect(f.world.destroy(r));
    try testing.expectEqualSlices(u32, &.{ 'E', 'D', 'C', 'B', 'A', 'R' }, order.seen[0..order.len]);
    try testing.expectEqual(@as(u32, 1), f.world.entityCount());
    try testing.expect(f.world.contains(keeper));
    // Still whether the root existed.
    try testing.expect(!f.world.destroy(r));
}

test "the cascade follows stored links through hostile data, and stops" {
    const gpa = testing.allocator;
    const f = try Fx.init(gpa, .default);
    defer f.deinit(gpa);
    const unit = core.math.Transform.identity;
    // A cycle through the root: r → x → y → r. Destroying r takes x and y.
    const r = try f.node(unit, null);
    const x = try f.node(unit, r);
    const y = try f.node(unit, x);
    try f.setRawParent(r, y);
    // A cycle elsewhere, a self-parent, and an orphan: none of them is r's, and none hangs.
    const p = try f.node(unit, null);
    const q = try f.node(unit, p);
    try f.setRawParent(p, q);
    const looped = try f.node(unit, null);
    try f.setRawParent(looped, looped);
    const orphan = try f.node(unit, null);
    try f.setRawParent(orphan, .{ .index = 9999, .generation = 1 });
    // An entity without a transform still takes its children with it.
    const bare = try f.world.create();
    const under = try f.node(unit, null);
    try setParent(&f.world, under, bare);

    try testing.expect(f.world.destroy(r));
    for ([_]Entity{ r, x, y }) |dead| try testing.expect(!f.world.contains(dead));
    for ([_]Entity{ p, q, looped, orphan }) |alive| try testing.expect(f.world.contains(alive));
    try testing.expect(f.world.destroy(bare));
    try testing.expect(!f.world.contains(under));
    try testing.expect(f.world.destroy(p));
    try testing.expect(!f.world.contains(q));
    try testing.expectEqual(@as(u32, 2), f.world.entityCount());
}

// -- the save round trip -------------------------------------------------------------

test "a saved hierarchy loads back to bit-identical world poses, and still cascades" {
    const gpa = testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var made: [tree.len]Entity = undefined;
    var poses: [tree.len]Mat4 = undefined;
    {
        const f = try Fx.init(gpa, .default);
        defer f.deinit(gpa);
        _ = try f.world.create(); // so no handle is slot zero by accident
        for (tree, 0..) |n, i| made[i] = try f.node(n.local, null);
        for (tree, 0..) |n, i| {
            if (n.parent) |parent| try setParent(&f.world, made[i], made[parent]);
        }
        _ = try propagate(&f.world);
        for (&poses, made) |*m, e| m.* = worldTransform(&f.world, e).?;
        try f.world.save(&bytes);
    }

    const g = try Fx.init(gpa, .default);
    defer g.deinit(gpa);
    _ = try g.world.load(bytes.items, .default);
    // Nothing derived was saved.
    try testing.expectEqual(@as(u32, 0), g.world.componentCount(g.types.world_transform));
    _ = try propagate(&g.world);
    for (poses, made) |m, e| {
        try testing.expectEqualSlices(u8, std.mem.asBytes(&m), std.mem.asBytes(&worldTransform(&g.world, e).?));
    }
    // The loaded parents reserved what the cascade needs.
    try testing.expect(g.world.destroy(made[1]));
    for ([_]usize{ 1, 3, 4 }) |i| try testing.expect(!g.world.contains(made[i]));
    for ([_]usize{ 0, 2 }) |i| try testing.expect(g.world.contains(made[i]));
}

test "keep-world holds across a sweep of rotated, uniformly scaled parents" {
    const gpa = testing.allocator;
    const f = try Fx.init(gpa, .default);
    defer f.deinit(gpa);
    // Deterministic, not random: the same sixty-four parents on every run.
    for (0..64) |i| {
        const k: f32 = @floatFromInt(i);
        const parent = try f.node(pose(.{ k * 0.37 - 5, 3 - k * 0.11, k * 0.05 }, .{ @sin(k), @cos(k * 1.3), 0.5 }, k * 0.41, @splat(0.3 + k * 0.07)), null);
        const child = try f.node(pose(.{ 1 - k * 0.2, k * 0.13, -2 }, .{ 0.2, @sin(k * 0.7), 1 }, -k * 0.23, .{ 1 + k * 0.01, 0.5, 2 }), null);
        const before = worldOf(&f.world, child).?;
        try setParentKeepWorld(&f.world, child, parent);
        try expectSamePose(before, worldOf(&f.world, child).?);
    }
}
