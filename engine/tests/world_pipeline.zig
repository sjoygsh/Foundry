//! A scene in a text file to a world reloaded from a save, through every step on the way.
//!
//! This is M4's exit criterion written down as one chain: `.fdt` text becomes a package,
//! the package becomes a store, a `foundry:scene` record becomes entities, systems advance
//! them at a fixed timestep, the world becomes a save, and a second world built from that
//! save carries on identically.
//!
//! Every one of those steps is unit-tested where it lives. What is only testable here is
//! that they compose — and specifically that the *same* schema serves all three of content,
//! storage and the save file, which is the load-bearing claim of `entity-storage.md` §3 and
//! the reason a component type is a schema rather than a thing with a schema.
//!
//! It also stands where a game stands: `data` and `scene` are siblings at L1 and L3 and
//! neither reaches the other's test code, so composing them is a consumer's job.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const scene = @import("scene");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Entity = scene.Entity;

// -- what the game defines ----------------------------------------------------------

const Position = struct {
    pub const component = "demo:position";
    x: f32 = 0,
    y: f32 = 0,
};

const Velocity = struct {
    pub const component = "demo:velocity";
    dx: f32 = 0,
    dy: f32 = 0,
};

/// Holds another entity, which is the field that only means anything because a save
/// preserves identity exactly (§9).
const Follows = struct {
    pub const component = "demo:follows";
    target: Entity = .none,
};

/// Integrates position from velocity at the fixed delta it is handed.
///
/// A function of the tick and nothing else: no clock, no input, no allocation. That is
/// what makes running it twice produce the same answer (I9), and `scene`'s layering is
/// what makes it impossible to write it any other way.
fn moveSystem(_: ?*anyopaque, world: *scene.World, tick: scene.Tick) void {
    const dt = tick.delta.toSecondsF32();
    var it = world.queryOf(.{ Position, Velocity });
    while (it.next()) |m| {
        const p = m.get(Position);
        const v = m.get(Velocity);
        p.x += v.dx * dt;
        p.y += v.dy * dt;
    }
}

/// Each follower takes a step toward whatever it follows. Present so that an entity
/// reference is *used* by the simulation rather than merely stored and compared.
fn followSystem(_: ?*anyopaque, world: *scene.World, tick: scene.Tick) void {
    const dt = tick.delta.toSecondsF32();
    var it = world.queryOf(.{ Follows, Position });
    while (it.next()) |m| {
        const target = m.get(Follows).target;
        const goal = world.getComponent(target, world.findComponent(
            comptime schemaIdOf(Position),
        ).?) orelse continue;
        const p = m.get(Position);
        const at: *const Position = @ptrCast(@alignCast(goal.ptr));
        p.x += (at.x - p.x) * dt;
        p.y += (at.y - p.y) * dt;
    }
}

fn schemaIdOf(comptime T: type) data.SchemaId {
    return scene.componentType(T).schema.id;
}

const scene_source =
    \\@schema demo:position { x f32 (default 0.0)  y f32 (default 0.0) }
    \\@schema demo:velocity { dx f32 (default 0.0)  dy f32 (default 0.0) }
    \\
    \\demo:position demo:pos.origin { }
    \\demo:position demo:pos.east   { x 100.0 }
    \\demo:position demo:pos.north  { y 100.0 }
    \\demo:velocity demo:vel.slow   { dx 1.0   dy 0.5 }
    \\demo:velocity demo:vel.fast   { dx -12.0 dy 7.25 }
    \\
    \\foundry:entity demo:entity.drifter { components [ demo:pos.origin  demo:vel.slow ] }
    \\foundry:entity demo:entity.racer   { components [ demo:pos.east    demo:vel.fast ] }
    \\foundry:entity demo:entity.marker  { components [ demo:pos.north ] }
    \\
    \\foundry:scene demo:scene.field {
    \\    entities [
    \\        demo:entity.drifter
    \\        demo:entity.racer
    \\        demo:entity.marker
    \\        demo:entity.drifter
    \\    ]
    \\}
;

// -- the stack ----------------------------------------------------------------------

/// The content pipeline, assembled exactly as `fpack` and the engine assemble it.
///
/// Two registries, and that is the point rather than an accident. The content one is
/// rebuilt from packages on every hot reload; the world's holds schemas declared by code
/// and outlives any reload. Nothing before a spawn can therefore notice that a package
/// declared a component's fields in a different order, which is why `World.attach` checks.
const Content = struct {
    gpa: Allocator,
    schemas: data.Registry,
    diags: data.Diagnostics,
    store: data.Store,
    bytes: std.ArrayList(u8) = .empty,

    fn init(gpa: Allocator) !*Content {
        const self = try gpa.create(Content);
        self.* = .{
            .gpa = gpa,
            .schemas = .init(gpa, .default),
            .diags = .init(gpa, .default),
            .store = .init(gpa, .default),
        };
        errdefer self.deinit();

        // The engine's own record types, put into every content registry as it is built —
        // the same call `fpack` makes, so an author never declares `foundry:scene`.
        try scene.schemas.registerAll(gpa, &self.schemas);

        var doc = try data.parser.parse(gpa, "demo.fdt", scene_source, .{ .namespace = "demo" }, &self.diags);
        defer doc.deinit(gpa);

        var pkg = try data.check.Package.init(gpa, "demo:content", 1, .default);
        defer pkg.deinit(gpa);
        try pkg.addDocument(gpa, &doc, &self.schemas, &self.diags);
        try data.fpk.write(gpa, &pkg, &self.schemas, &self.bytes);
        _ = try self.store.add(gpa, "demo:content", self.bytes.items, &self.schemas, &self.diags);
        return self;
    }

    fn deinit(self: *Content) void {
        self.store.deinit(self.gpa);
        self.diags.deinit(self.gpa);
        self.schemas.deinit(self.gpa);
        self.bytes.deinit(self.gpa);
        self.gpa.destroy(self);
    }
};

/// A world with the three component types and two systems registered, and nothing in it.
const Game = struct {
    gpa: Allocator,
    schemas: data.Registry,
    world: scene.World,
    position: scene.ComponentType = .none,
    velocity: scene.ComponentType = .none,
    follows: scene.ComponentType = .none,

    fn init(gpa: Allocator) !*Game {
        const self = try gpa.create(Game);
        self.* = .{ .gpa = gpa, .schemas = .init(gpa, .default), .world = undefined };
        self.world = .init(gpa, &self.schemas, .default);
        self.position = try self.world.registerComponent(scene.componentType(Position));
        self.velocity = try self.world.registerComponent(scene.componentType(Velocity));
        self.follows = try self.world.registerComponent(scene.componentType(Follows));
        _ = try self.world.registerSystem(.{
            .id = try data.contentId("demo:system.move"),
            .name = "demo:system.move",
            .update = &moveSystem,
        });
        _ = try self.world.registerSystem(.{
            .id = try data.contentId("demo:system.follow"),
            .name = "demo:system.follow",
            .update = &followSystem,
        });
        return self;
    }

    fn deinit(self: *Game) void {
        self.world.deinit();
        self.schemas.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Runs `ticks` fixed steps, starting at `from`.
    fn run(self: *Game, from: u64, ticks: u64) void {
        var tick = from;
        while (tick < from + ticks) : (tick += 1) {
            self.world.update(.{ .tick = tick, .delta = core.time.Duration.fromNanos(16_666_667) });
        }
    }

    /// Every live entity's position, in query order — which is dense order, which is what
    /// a reload has to preserve for this to be comparable at all.
    fn positions(self: *Game, gpa: Allocator) ![]Position {
        var out: std.ArrayList(Position) = .empty;
        errdefer out.deinit(gpa);
        var it = self.world.query(&.{self.position});
        while (it.next()) |_| {
            try out.append(gpa, @as(*const Position, @ptrCast(@alignCast(it.bytes(0).ptr))).*);
        }
        return out.toOwnedSlice(gpa);
    }
};

fn expectSamePositions(a: []const Position, b: []const Position) !void {
    try testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| {
        // Bit-exact, deliberately. The same binary running the same fixed steps in the
        // same order must produce the same floats — that is what ADR-0013 promises, and
        // an epsilon here would hide exactly the drift the promise is about.
        try testing.expectEqual(x.x, y.x);
        try testing.expectEqual(x.y, y.y);
    }
}

// -- the exit criterion -------------------------------------------------------------

test "a scene from content, stepped, saved, and reloaded across a restart" {
    const gpa = testing.allocator;
    const content = try Content.init(gpa);
    defer content.deinit();

    const first = try Game.init(gpa);
    defer first.deinit();

    // Content data becomes entities. Nothing about this is engine-specific: the two record
    // types are `scene`'s, the component records are the game's, and a mod's would arrive
    // through the identical call (I3, I5).
    const spawned = try first.world.spawnScene(&content.store, try data.contentId("demo:scene.field"));
    try testing.expectEqual(@as(u32, 4), spawned);

    // One entity is given a reference to another, in code — a handle is not something
    // content can spell, and it is the thing a save has to carry correctly.
    var order: [4]Entity = undefined;
    var i: usize = 0;
    var it = first.world.query(&.{first.position});
    while (it.next()) |e| : (i += 1) order[i] = e;
    _ = try first.world.addComponent(order[2], first.follows, std.mem.asBytes(&Follows{ .target = order[1] }));

    // Systems advance it at a fixed timestep.
    first.run(0, 90);
    const before = try first.positions(gpa);
    defer gpa.free(before);

    // The world becomes bytes. `scene` cannot open a file, so this is where a game would
    // hand them to `platform` — and why the whole test is hermetic.
    var saved: std.ArrayList(u8) = .empty;
    defer saved.deinit(gpa);
    try first.world.save(&saved);

    // A second process, in effect: a brand-new world that has never seen the content.
    const second = try Game.init(gpa);
    defer second.deinit();
    const summary = try second.world.load(saved.items, .default);
    try testing.expectEqual(@as(u32, 4), summary.entities);
    // Four positions, three velocities (the marker has none), one follows.
    try testing.expectEqual(@as(u32, 8), summary.components);
    try testing.expectEqual(@as(u32, 0), summary.skipped_types);

    // Identical state, in identical order.
    const after = try second.positions(gpa);
    defer gpa.free(after);
    try expectSamePositions(before, after);

    // The same handles, including the reference one entity holds to another.
    for (order) |e| try testing.expect(second.world.contains(e));
    const follows: *const Follows = @ptrCast(@alignCast(
        second.world.getComponent(order[2], second.follows).?.ptr,
    ));
    try testing.expect(follows.target.eql(order[1]));

    // And they carry on the same: 90 more ticks on each, still identical. A save that got
    // the state right and the *order* wrong would diverge here, because `followSystem`
    // reads one entity while writing another.
    first.run(90, 90);
    second.run(90, 90);
    const first_end = try first.positions(gpa);
    defer gpa.free(first_end);
    const second_end = try second.positions(gpa);
    defer gpa.free(second_end);
    try expectSamePositions(first_end, second_end);

    // Saving each of them again produces the same bytes, which is the strongest form of
    // "the reload changed nothing".
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try first.world.save(&a);
    try second.world.save(&b);
    try testing.expectEqualSlices(u8, a.items, b.items);
}

test "the same fixed scenario run twice produces identical state" {
    const gpa = testing.allocator;
    const content = try Content.init(gpa);
    defer content.deinit();

    var runs: [2][]Position = undefined;
    for (&runs) |*out| {
        const game = try Game.init(gpa);
        defer game.deinit();
        _ = try game.world.spawnScene(&content.store, try data.contentId("demo:scene.field"));
        game.run(0, 240);
        out.* = try game.positions(gpa);
    }
    defer for (runs) |r| gpa.free(r);

    try expectSamePositions(runs[0], runs[1]);
}

test "content that names a component this build does not have is refused, not guessed" {
    const gpa = testing.allocator;
    const content = try Content.init(gpa);
    defer content.deinit();

    // A world with only `demo:position` registered. The scene's records name a velocity
    // too, and a spawn that quietly dropped it would produce entities that look right and
    // do not move.
    var schemas: data.Registry = .init(gpa, .default);
    defer schemas.deinit(gpa);
    var world: scene.World = .init(gpa, &schemas, .default);
    defer world.deinit();
    _ = try world.registerComponent(scene.componentType(Position));

    try testing.expectError(
        error.UnknownComponentType,
        world.spawnScene(&content.store, try data.contentId("demo:scene.field")),
    );
    // All or nothing: the half-built entities are gone.
    try testing.expectEqual(@as(u32, 0), world.entityCount());
}
