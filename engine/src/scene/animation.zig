//! `foundry:animator` and `foundry:root_motion`: animation in a world (`animation-logic.md` §7,
//! ADR-0071).
//!
//! **`foundry:animator` is `anim.Player` under an engine name,** as `foundry:transform` is
//! `core.Transform`, plus the set it plays. `derive` takes no arrays, so its four channels are
//! fields of their own, and a layout check keeps it and `anim.Player` the same. Authoring names
//! only the set.
//!
//! **A world opts in** with `World.enableAnimation`.
//!
//! **A save holds no pose.** A pose is a function of a player and a rig, so a load reproduces it
//! exactly. `foundry:root_motion` is this tick's move, derived and unsaved, like
//! `foundry:world_transform`.
//!
//! **`scene` still sees no asset.** Its calls take a `RigSource`, so its tests stay hermetic. A game
//! makes one from `asset.Rigs` with `rigSource`.
//!
//! **`advance` is a function, not a registered system,** because a game's order matters here: it
//! decides what to play, advances, moves its bodies with the deltas, then propagates. A `System`
//! can wrap it in one line.
//!
//! **Everything here is untrusted:** a saved or raw-written animator is repaired by `anim.Player`,
//! and an animator whose set is gone stays in the world, unadvanced and counted.

const std = @import("std");
const anim = @import("anim");
const core = @import("core");
const data = @import("data");

const component = @import("component.zig");
const derive = @import("derive.zig");
const entity_mod = @import("entity.zig");
const world_mod = @import("world.zig");

const Allocator = std.mem.Allocator;
const Channel = anim.Channel;
const ComponentType = component.ComponentType;
const ComponentTypeInfo = component.ComponentTypeInfo;
const ContentId = core.ContentId;
const Entity = entity_mod.Entity;
const Transform = core.math.Transform;
const Vec3 = core.math.Vec3;
const World = world_mod.World;

pub const animator_name = "foundry:animator";
pub const root_motion_name = "foundry:root_motion";

/// A set to play, and how far it has got. Saved and authorable.
pub const Animator = extern struct {
    pub const component = animator_name;

    /// The `foundry:animation_set` this plays.
    set: ContentId = .none,
    c0: Channel = .{},
    c1: Channel = .{},
    c2: Channel = .{},
    c3: Channel = .{},
    fade: f32 = 0,
    newest: u32 = 0,
    dt: f32 = 0,

    pub fn player(self: *Animator) *anim.Player {
        return @ptrCast(&self.c0);
    }

    pub fn constPlayer(self: *const Animator) *const anim.Player {
        return @ptrCast(&self.c0);
    }
};

comptime {
    const P = anim.Player;
    const base = @offsetOf(Animator, "c0");
    std.debug.assert(anim.max_channels == 4);
    std.debug.assert(base % @alignOf(P) == 0);
    std.debug.assert(@alignOf(Animator) >= @alignOf(P));
    std.debug.assert(@sizeOf(Animator) >= base + @sizeOf(P));
    for (.{ "c0", "c1", "c2", "c3" }, 0..) |field, i| {
        std.debug.assert(@offsetOf(Animator, field) == base + @offsetOf(P, "channels") + i * @sizeOf(Channel));
    }
    for (.{ "fade", "newest", "dt" }) |field| {
        std.debug.assert(@offsetOf(Animator, field) == base + @offsetOf(P, field));
    }
}

/// This tick's move, in the body's frame at the tick's start (`anim.Motion`). Written by `advance`,
/// never saved, never authored. Only an entity whose rig carries motion has one.
pub const RootMotion = extern struct {
    translation: Vec3 = Vec3.zero,
    yaw: f32 = 0,
};

/// The two types, as one world registered them.
pub const Types = struct {
    animator: ComponentType,
    root_motion: ComponentType,
};

/// The schema content is compiled against, and the one the world registers.
pub const animator_schema: data.Schema = derive.componentType(Animator).schema;

pub fn animatorInfo() ComponentTypeInfo {
    var info = derive.componentType(Animator);
    info.deserialize = &deserializeAnimator;
    return info;
}

fn deserializeAnimator(ctx: ?*anyopaque, fields: data.fpk.Fields, out: [*]u8) component.DeserializeError!void {
    const derived = comptime derive.componentType(Animator).deserialize.?;
    try derived(ctx, fields, out);
    const value: *const Animator = @ptrCast(@alignCast(out));
    if (!value.constPlayer().sane()) return error.ValueOutOfRange;
}

pub fn rootMotionInfo() ComponentTypeInfo {
    return .{
        .schema = .{
            .id = data.SchemaId.fromStringUnchecked(root_motion_name),
            .version = 1,
            .fields = &.{},
        },
        .name = root_motion_name,
        .size = @sizeOf(RootMotion),
        .alignment = @alignOf(RootMotion),
        .construct = &constructRootMotion,
    };
}

fn constructRootMotion(_: ?*anyopaque, out: [*]u8) void {
    const value: *RootMotion = @ptrCast(@alignCast(out));
    value.* = .{};
}

/// Where rigs come from, which `scene` can't name. Null for a set with no rig.
pub const RigSource = struct {
    ctx: *const anyopaque,
    lookup: *const fn (ctx: *const anyopaque, set: ContentId) ?*const anim.Rig,

    fn rig(self: RigSource, set: ContentId) ?*const anim.Rig {
        return self.lookup(self.ctx, set);
    }
};

/// A source over anything with `lookup(set) ?*const anim.Rig`, which is what `asset.Rigs` has.
pub fn rigSource(rigs: anytype) RigSource {
    const Rigs = @typeInfo(@TypeOf(rigs)).pointer.child;
    return .{
        .ctx = rigs,
        .lookup = struct {
            fn lookup(ctx: *const anyopaque, set: ContentId) ?*const anim.Rig {
                const self: *const Rigs = @ptrCast(@alignCast(ctx));
                return self.lookup(set);
            }
        }.lookup,
    };
}

pub const Fired = struct {
    entity: Entity,
    event: ContentId,
};

/// A game's bounded list of this tick's events, in entity order. What does not fit is counted.
pub const Events = struct {
    buffer: []Fired,
    count: usize = 0,
    dropped: u32 = 0,

    pub fn fired(self: *const Events) []const Fired {
        return self.buffer[0..self.count];
    }

    fn add(self: *Events, fired_event: Fired) void {
        if (self.count == self.buffer.len) {
            self.dropped +|= 1;
            return;
        }
        self.buffer[self.count] = fired_event;
        self.count += 1;
    }
};

pub const Options = struct {
    /// Null when a game listens for none: they are then counted and thrown away.
    events: ?*Events = null,
    /// Filled for the overlay's panel, when a game shows it (`animation-logic.md` §8).
    report: ?*anim.Report = null,
};

/// What a tick did, across a world.
pub const Summary = struct {
    animators: u32 = 0,
    /// Animators whose set has no rig: left as they were, and resumed if it returns.
    unresolved: u32 = 0,
    /// Channels emptied, as `anim.Step.lost`.
    lost: u32 = 0,
    events: u32 = 0,
    /// Events no player or list could hold.
    dropped: u32 = 0,
};

/// One tick of every animator in a world with animation. An error leaves the tick undone.
pub fn advance(world: *World, rigs: RigSource, dt: f32, options: Options) Allocator.Error!Summary {
    const types = world.animation orelse return .{};
    try addMotion(world, types, rigs);

    const first = if (options.events) |list| list.count else 0;
    var summary: Summary = .{};
    var step: anim.Step = .{};
    var query = world.query(&.{types.animator});
    while (query.next()) |entity| {
        const animator: *Animator = @ptrCast(@alignCast(query.bytes(0).ptr));
        summary.animators += 1;
        const rig = rigs.rig(animator.set) orelse {
            summary.unresolved += 1;
            continue;
        };
        animator.player().advance(rig.*, dt, &step);
        summary.lost +|= step.lost;
        summary.events +|= step.event_count;
        summary.dropped +|= step.dropped;
        if (options.events) |list| {
            for (step.fired()) |event| list.add(.{ .entity = entity, .event = event });
        }
        if (options.report) |report| {
            var label: [32]u8 = undefined;
            report.add(animator.constPlayer(), rig.*, std.fmt.bufPrint(&label, "entity {d}.{d}", .{ entity.index, entity.generation }) catch "entity", &step);
        }
        if (rig.motion_joint == anim.no_parent) continue;
        const motion: *RootMotion = @ptrCast(@alignCast((world.getComponent(entity, types.root_motion) orelse continue).ptr));
        motion.* = .{ .translation = step.motion.translation, .yaw = step.motion.yaw };
    }
    if (options.events) |list| {
        summary.dropped +|= list.dropped;
        // A store's order is its history, and a list's order is a contract. Stable, so each
        // entity's events stay in time order.
        std.sort.block(Fired, list.buffer[first..list.count], {}, lessByEntity);
    }
    return summary;
}

fn lessByEntity(_: void, a: Fired, b: Fired) bool {
    return a.entity.index < b.entity.index;
}

/// Gives each animator whose rig carries motion its `foundry:root_motion`. Apart from the walk
/// above, since adding a component during a query is a structural change. A load drops the
/// component, so this is also what brings it back.
fn addMotion(world: *World, types: Types, rigs: RigSource) Allocator.Error!void {
    var missing: std.ArrayList(Entity) = .empty;
    defer missing.deinit(world.gpa);
    var query = world.query(&.{types.animator});
    while (query.next()) |entity| {
        const animator: *const Animator = @ptrCast(@alignCast(query.bytes(0).ptr));
        const rig = rigs.rig(animator.set) orelse continue;
        if (rig.motion_joint == anim.no_parent or world.hasComponent(entity, types.root_motion)) continue;
        try missing.append(world.gpa, entity);
    }
    for (missing.items) |entity| {
        var value: RootMotion = .{};
        _ = world.addComponent(entity, types.root_motion, std.mem.asBytes(&value)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The entity and the type were just read, and it had none.
            else => unreachable,
        };
    }
}

/// An entity's player, for `play`, `setSpeed` and `seek`. Null without an animator. A borrow,
/// valid until the next structural change of the world.
pub fn player(world: *World, entity: Entity) ?*anim.Player {
    const animator = animatorOf(world, entity) orelse return null;
    return animator.player();
}

/// An entity's animator. A borrow, as `player`'s.
pub fn animatorOf(world: *World, entity: Entity) ?*Animator {
    const types = world.animation orelse return null;
    const bytes = world.getComponent(entity, types.animator) orelse return null;
    return @ptrCast(@alignCast(bytes.ptr));
}

/// An entity's move this tick, or null if it has none.
pub fn motionOf(world: *const World, entity: Entity) ?RootMotion {
    const types = world.animation orelse return null;
    const bytes = world.readComponent(entity, types.root_motion) orelse return null;
    return std.mem.bytesToValue(RootMotion, bytes);
}

/// One entity's pose, into a game's two buffers, each at least the rig's joint count. Returns the
/// joint count, or null with no animator, no rig or buffers too short.
pub fn evaluate(world: *World, entity: Entity, rigs: RigSource, scratch: []Transform, out: []Transform) ?usize {
    const animator = animatorOf(world, entity) orelse return null;
    const rig = rigs.rig(animator.set) orelse return null;
    const joints = rig.skeleton.jointCount();
    if (scratch.len < joints or out.len < joints) return null;
    animator.constPlayer().evaluate(rig.*, .{ .local = scratch[0..joints] }, .{ .local = out[0..joints] });
    return joints;
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;
const gpa = testing.allocator;
const Mat4 = core.math.Mat4;

const tick: f32 = 1.0 / 60.0;

const parents = [_]u16{anim.no_parent};
const rest = [_]Transform{.{}};
const binds = [_]Mat4{Mat4.identity};
const ends = [_]f32{ 0, 1 };
const forward = [_]f32{ 0, 0, 0, 0, 0, -0.6 };
const tracks = [_]anim.Track{.{ .joint = 0, .path = .translation, .times = &ends, .values = &forward }};
const swing = [_]f32{ 0, 0, 0, 1, 0, 0 };
const swing_tracks = [_]anim.Track{.{ .joint = 0, .path = .translation, .times = &ends, .values = &swing }};

const foot: ContentId = .fromString("test:foot");
const step_events = [_]anim.Event{ .{ .at = 0.1, .id = foot }, .{ .at = 0.6, .id = foot } };
const many_events = [_]anim.Event{ .{ .at = 0, .id = foot }, .{ .at = 0.001, .id = foot } };

const set_walk: ContentId = .fromString("test:set.walk");
const set_still: ContentId = .fromString("test:set.still");
const set_gone: ContentId = .fromString("test:set.gone");

const walk_clips = [_]anim.RigClip{.{ .name = 5, .clip = .{ .duration = 1, .tracks = &tracks }, .motion = true, .events = &step_events }};
const walk_rig: anim.Rig = .{
    .skeleton = .{ .parents = &parents, .rest = &rest, .inverse_bind = &binds },
    .clips = &walk_clips,
    .start = 5,
    .motion_joint = 0,
};
const still_clips = [_]anim.RigClip{.{ .name = 9, .clip = .{ .duration = 1, .tracks = &swing_tracks }, .events = &many_events }};
const still_rig: anim.Rig = .{
    .skeleton = .{ .parents = &parents, .rest = &rest, .inverse_bind = &binds },
    .clips = &still_clips,
    .start = 9,
};

const FakeRigs = struct {
    fn lookup(_: *const FakeRigs, set: ContentId) ?*const anim.Rig {
        if (set.eql(set_walk)) return &walk_rig;
        if (set.eql(set_still)) return &still_rig;
        return null;
    }
};
const fake: FakeRigs = .{};

const Fixture = struct {
    schemas: data.Registry,
    world: World,

    fn init(self: *Fixture) !void {
        self.schemas = .init(gpa, .default);
        self.world = .init(gpa, &self.schemas, .{});
        _ = try self.world.enableAnimation();
    }

    fn deinit(self: *Fixture) void {
        self.world.deinit();
        self.schemas.deinit(gpa);
    }

    fn spawn(self: *Fixture, set: ContentId) !Entity {
        const entity = try self.world.create();
        var animator: Animator = .{ .set = set };
        _ = try self.world.addComponent(entity, self.world.animation.?.animator, std.mem.asBytes(&animator));
        return entity;
    }
};

/// Every byte that matters from one tick: pose, motion and events.
fn feed(hash: *u64, f: *Fixture, entity: Entity, events: *const Events) void {
    var a: [1]Transform = undefined;
    var b: [1]Transform = undefined;
    _ = evaluate(&f.world, entity, rigSource(&fake), &b, &a).?;
    const pose = [_]f32{ a[0].translation.x, a[0].translation.y, a[0].translation.z };
    const motion = motionOf(&f.world, entity).?;
    for (std.mem.sliceAsBytes(&pose)) |byte| hash.* = (hash.* ^ byte) *% 0x100000001b3;
    for (std.mem.asBytes(&motion)) |byte| hash.* = (hash.* ^ byte) *% 0x100000001b3;
    for (events.fired()) |fired| {
        for (std.mem.asBytes(&fired.event.hash)) |byte| hash.* = (hash.* ^ byte) *% 0x100000001b3;
    }
}

test "enabling animation registers both types, once, and only before the first entity" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const types = f.world.animation.?;
    try testing.expect(f.world.componentInfo(types.animator).?.savable());
    try testing.expect(!f.world.componentInfo(types.root_motion).?.savable());
    const again = try f.world.enableAnimation();
    try testing.expect(again.animator.eql(types.animator));
    try testing.expectEqual(@as(u32, 2), f.world.componentTypeCount());

    var schemas: data.Registry = .init(gpa, .default);
    defer schemas.deinit(gpa);
    var late: World = .init(gpa, &schemas, .{});
    defer late.deinit();
    _ = try late.create();
    try testing.expectError(error.WorldNotEmpty, late.enableAnimation());
    try testing.expect(late.animation == null);

    var one: World = .init(gpa, &schemas, .{ .max_component_types = 1 });
    defer one.deinit();
    try testing.expectError(error.ComponentTypeLimit, one.enableAnimation());
    try testing.expectEqual(@as(u32, 0), one.componentTypeCount());
}

test "a world without animation advances nothing and answers null" {
    var schemas: data.Registry = .init(gpa, .default);
    defer schemas.deinit(gpa);
    var world: World = .init(gpa, &schemas, .{});
    defer world.deinit();
    const entity = try world.create();
    try testing.expectEqual(@as(u32, 0), (try advance(&world, rigSource(&fake), tick, .{})).animators);
    try testing.expect(player(&world, entity) == null);
    try testing.expect(motionOf(&world, entity) == null);
}

test "an animator plays its set, and a body gets its move each tick" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const entity = try f.spawn(set_walk);
    try testing.expect(motionOf(&f.world, entity) == null);

    var travelled: f32 = 0;
    var fired: [8]Fired = undefined;
    var total: usize = 0;
    for (0..30) |_| {
        var events: Events = .{ .buffer = &fired };
        const summary = try advance(&f.world, rigSource(&fake), tick, .{ .events = &events });
        try testing.expectEqual(@as(u32, 1), summary.animators);
        travelled += motionOf(&f.world, entity).?.translation.z;
        total += events.count;
        if (events.count != 0) try testing.expect(events.fired()[0].entity.eql(entity));
    }
    try testing.expectApproxEqAbs(@as(f32, -0.3), travelled, 1e-4);
    try testing.expectEqual(@as(usize, 1), total);

    // A game reaches the player between ticks.
    try player(&f.world, entity).?.setSpeed(walk_rig, 2);
    _ = try advance(&f.world, rigSource(&fake), tick, .{});
    try testing.expectApproxEqAbs(@as(f32, -0.6 * 2.0 * tick), motionOf(&f.world, entity).?.translation.z, 1e-5);
}

test "an entity whose rig carries no motion gains no root motion" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const entity = try f.spawn(set_still);
    _ = try advance(&f.world, rigSource(&fake), tick, .{});
    try testing.expect(motionOf(&f.world, entity) == null);
}

test "evaluate fills a game's buffers, and refuses what it can't do" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const entity = try f.spawn(set_still);
    const lost = try f.spawn(set_gone);
    const bare = try f.world.create();
    for (0..30) |_| _ = try advance(&f.world, rigSource(&fake), tick, .{});
    var a: [2]Transform = undefined;
    var b: [2]Transform = undefined;
    try testing.expectEqual(@as(?usize, 1), evaluate(&f.world, entity, rigSource(&fake), &b, &a));
    try testing.expectApproxEqAbs(@as(f32, 0.5), a[0].translation.x, 1e-4);
    try testing.expect(evaluate(&f.world, lost, rigSource(&fake), &b, &a) == null);
    try testing.expect(evaluate(&f.world, bare, rigSource(&fake), &b, &a) == null);
    try testing.expect(evaluate(&f.world, entity, rigSource(&fake), b[0..0], &a) == null);
    try testing.expect(evaluate(&f.world, entity, rigSource(&fake), &b, a[0..0]) == null);
}

test "events come in entity order, each entity's in time order, and what won't fit is counted" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const first = try f.spawn(set_still);
    const second = try f.spawn(set_still);
    const third = try f.spawn(set_still);
    // Removing and adding reorders the dense store without changing what an order may depend on.
    try testing.expect(f.world.removeComponent(first, f.world.animation.?.animator));
    var animator: Animator = .{ .set = set_still };
    _ = try f.world.addComponent(first, f.world.animation.?.animator, std.mem.asBytes(&animator));

    var buffer: [8]Fired = undefined;
    var events: Events = .{ .buffer = &buffer };
    // Each fires two: both of `many_events` lie in the first tick.
    _ = try advance(&f.world, rigSource(&fake), tick, .{ .events = &events });
    try testing.expectEqual(@as(usize, 6), events.count);
    for ([_]Entity{ first, first, second, second, third, third }, events.fired()) |entity, fired| {
        try testing.expect(fired.entity.eql(entity));
    }

    var short: [3]Fired = undefined;
    var few: Events = .{ .buffer = &short };
    const players = [_]Entity{ first, second, third };
    for (players) |entity| try player(&f.world, entity).?.play(still_rig, 9, .{});
    const summary = try advance(&f.world, rigSource(&fake), tick, .{ .events = &few });
    try testing.expectEqual(@as(usize, 3), few.count);
    try testing.expectEqual(@as(u32, 3), few.dropped);
    try testing.expectEqual(@as(u32, 3), summary.dropped);
    try testing.expectEqual(@as(u32, 6), summary.events);
}

test "a list that already holds events keeps them, and sorts only its own" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.spawn(set_still);
    var buffer: [4]Fired = undefined;
    buffer[0] = .{ .entity = .{ .index = 99, .generation = 1 }, .event = foot };
    var events: Events = .{ .buffer = &buffer, .count = 1 };
    _ = try advance(&f.world, rigSource(&fake), tick, .{ .events = &events });
    try testing.expectEqual(@as(usize, 3), events.count);
    try testing.expectEqual(@as(u32, 99), events.fired()[0].entity.index);
}

test "a world saved mid-stride and loaded continues byte-identical to the one that was not" {
    var a: Fixture = undefined;
    try a.init();
    defer a.deinit();
    const entity = try a.spawn(set_walk);
    for (0..47) |_| _ = try advance(&a.world, rigSource(&fake), tick, .{});
    try player(&a.world, entity).?.setSpeed(walk_rig, 1.5);
    for (0..5) |_| _ = try advance(&a.world, rigSource(&fake), tick, .{});

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try a.world.save(&bytes);

    var b: Fixture = undefined;
    try b.init();
    defer b.deinit();
    const summary = try b.world.load(bytes.items, .default);
    try testing.expect(b.world.contains(entity));
    try testing.expectEqual(@as(u32, 1), summary.entities);

    // No pose was saved, and yet the first evaluation agrees.
    var pose_a: [1]Transform = undefined;
    var pose_b: [1]Transform = undefined;
    var scratch: [1]Transform = undefined;
    _ = evaluate(&a.world, entity, rigSource(&fake), &scratch, &pose_a).?;
    _ = evaluate(&b.world, entity, rigSource(&fake), &scratch, &pose_b).?;
    try testing.expectEqual(pose_a[0], pose_b[0]);

    // `foundry:root_motion` was not saved, and the first tick brings it back.
    try testing.expect(motionOf(&b.world, entity) == null);

    var hash_a: u64 = 0xcbf29ce484222325;
    var hash_b: u64 = 0xcbf29ce484222325;
    var buffer: [8]Fired = undefined;
    for (0..240) |_| {
        var events_a: Events = .{ .buffer = &buffer };
        _ = try advance(&a.world, rigSource(&fake), tick, .{ .events = &events_a });
        feed(&hash_a, &a, entity, &events_a);
        var events_b: Events = .{ .buffer = &buffer };
        _ = try advance(&b.world, rigSource(&fake), tick, .{ .events = &events_b });
        feed(&hash_b, &b, entity, &events_b);
    }
    try testing.expectEqual(hash_a, hash_b);

    // A save does not grow with play, since it holds no pose and no history.
    var again: std.ArrayList(u8) = .empty;
    defer again.deinit(gpa);
    try b.world.save(&again);
    try testing.expectEqual(bytes.items.len, again.items.len);
}

fn saveWith(f: *Fixture, entity: Entity, field_edit: *const fn (*Animator) void) !std.ArrayList(u8) {
    field_edit(animatorOf(&f.world, entity).?);
    var bytes: std.ArrayList(u8) = .empty;
    try f.world.save(&bytes);
    return bytes;
}

test "a save with bad values is refused, by each of them" {
    const edits = [_]*const fn (*Animator) void{
        struct {
            fn edit(a: *Animator) void {
                a.c0.speed = std.math.nan(f32);
            }
        }.edit,
        struct {
            fn edit(a: *Animator) void {
                a.c1.weight = 2;
            }
        }.edit,
        struct {
            fn edit(a: *Animator) void {
                a.c2.anchor = -1;
            }
        }.edit,
        struct {
            fn edit(a: *Animator) void {
                a.c3.speed = 100;
            }
        }.edit,
        struct {
            fn edit(a: *Animator) void {
                a.newest = 4;
            }
        }.edit,
        struct {
            fn edit(a: *Animator) void {
                a.fade = -1;
            }
        }.edit,
        struct {
            fn edit(a: *Animator) void {
                a.dt = std.math.inf(f32);
            }
        }.edit,
    };
    for (edits) |edit| {
        var a: Fixture = undefined;
        try a.init();
        defer a.deinit();
        const entity = try a.spawn(set_walk);
        for (animatorOf(&a.world, entity).?.constPlayer().channels, 0..) |_, i| {
            // Each channel is in use, so that a bad value in any of them counts.
            animatorOf(&a.world, entity).?.player().channels[i].clip = 5;
        }
        var bytes = try saveWith(&a, entity, edit);
        defer bytes.deinit(gpa);

        var b: Fixture = undefined;
        try b.init();
        defer b.deinit();
        try testing.expectError(error.SaveCorrupt, b.world.load(bytes.items, .default));
    }
}

test "a save whose set is gone stays, unadvanced and counted, and resumes if it returns" {
    var a: Fixture = undefined;
    try a.init();
    defer a.deinit();
    const entity = try a.spawn(set_walk);
    for (0..10) |_| _ = try advance(&a.world, rigSource(&fake), tick, .{});
    const before = animatorOf(&a.world, entity).?.*;

    const Empty = struct {
        fn lookup(_: *const @This(), _: ContentId) ?*const anim.Rig {
            return null;
        }
    };
    const empty: Empty = .{};
    for (0..10) |_| {
        const summary = try advance(&a.world, rigSource(&empty), tick, .{});
        try testing.expectEqual(@as(u32, 1), summary.unresolved);
    }
    try testing.expectEqual(before, animatorOf(&a.world, entity).?.*);
    try testing.expect(evaluate(&a.world, entity, rigSource(&empty), &[_]Transform{}, &[_]Transform{}) == null);
    const summary = try advance(&a.world, rigSource(&fake), tick, .{});
    try testing.expectEqual(@as(u32, 0), summary.unresolved);
    try testing.expectEqual(before.c0.ticks + 1, animatorOf(&a.world, entity).?.c0.ticks);
}

test "a raw write no deserializer saw is repaired, counted and never asserted on" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const entity = try f.spawn(set_walk);
    _ = try advance(&f.world, rigSource(&fake), tick, .{});
    const animator = animatorOf(&f.world, entity).?;
    animator.c0.speed = std.math.nan(f32);
    animator.newest = 99;
    const summary = try advance(&f.world, rigSource(&fake), tick, .{});
    try testing.expectEqual(@as(u32, 1), summary.lost);
    try testing.expect(animatorOf(&f.world, entity).?.constPlayer().sane());
}

test "a report lists a world's animators" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.spawn(set_walk);
    _ = try f.spawn(set_gone);
    var report: anim.Report = .{};
    _ = try advance(&f.world, rigSource(&fake), tick, .{ .report = &report });
    try testing.expectEqual(@as(u32, 1), report.players);
    try testing.expectEqualStrings("entity 0.1", report.rows[0].label());
}

test "out of memory while adding root motion leaves the tick undone" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const entity = try f.spawn(set_walk);
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const held = f.world.gpa;
    f.world.gpa = failing.allocator();
    defer f.world.gpa = held;
    try testing.expectError(error.OutOfMemory, advance(&f.world, rigSource(&fake), tick, .{}));
    try testing.expectEqual(@as(u64, 0), animatorOf(&f.world, entity).?.c0.ticks);
}

test "an animator is authored by naming a set, and a bad one is refused" {
    var schemas: data.Registry = .init(gpa, .default);
    defer schemas.deinit(gpa);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    const entity_schemas = @import("schemas.zig");
    try entity_schemas.registerAll(gpa, &schemas);
    var package = try data.Package.init(gpa, "t:content", 1, .default);
    defer package.deinit(gpa);
    var doc = try data.parser.parse(gpa, "t.fdt",
        \\foundry:animator t:a { set t:set }
        \\foundry:animator t:bad { set t:set c0 { clip 5 speed 99 weight 1 } }
        \\foundry:entity t:hero { components [ t:a ] }
        \\foundry:entity t:broken { components [ t:bad ] }
    , .{ .namespace = "t" }, &diags);
    defer doc.deinit(gpa);
    try package.addDocument(gpa, &doc, &schemas, &diags);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try data.fpk.write(gpa, &package, &schemas, &bytes);
    var store: data.Store = .init(gpa, .default);
    defer store.deinit(gpa);
    _ = try store.add(gpa, "t.fpk", bytes.items, &schemas, &diags);

    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const entity = try f.world.spawn(&store, .fromString("t:hero"));
    try testing.expect(animatorOf(&f.world, entity).?.set.eql(.fromString("t:set")));
    try testing.expectEqual(anim.Player{}, animatorOf(&f.world, entity).?.constPlayer().*);
    try testing.expectError(error.ValueOutOfRange, f.world.spawn(&store, .fromString("t:broken")));
}
