//! The sample's world: nested moving objects (`docs/design/hierarchy.md` §8).
//!
//! **An orrery on the table.** A turntable turns; a crate rides on it and turns about its own
//! axis; a smaller crate orbits that one because it is that one's child. Beside it a frame
//! scaled `(2, 1, 1)` carries a child turned 45°, so a sheared world is on screen, drawn
//! correctly, and M19's code-built cube is one more entity with a spin.
//!
//! Each object is a template in the package: its `foundry:transform`, its model and its spin.
//! **The parents are set here, in code**, because a parent is an entity handle and content
//! never authors one (§3.3). `sandbox3d:systems.spin` writes the local poses and
//! `foundry:systems.propagate_transforms` runs after it, in that registration order.
//!
//! This file knows nothing about drawing. The sample reads each `sandbox3d:model`'s world
//! pose from here and draws it through `render3d.Content`.

const std = @import("std");

const core = @import("core");
const data = @import("data");
const scene = @import("scene");

const hierarchy = scene.hierarchy;
const Entity = scene.Entity;
const Mat4 = core.math.Mat4;
const Quat = core.math.Quat;
const Vec3 = core.math.Vec3;

const log = core.log.scoped(.sandbox3d);

/// Names a model by content ID: the "whatever component a game uses" of `3d.md` §3.
pub const Model = struct {
    pub const component = "sandbox3d:model";
    model: core.ContentId = .none,
};

/// A turn about the entity's own axis, in radians per second.
pub const Spin = struct {
    pub const component = "sandbox3d:spin";
    axis: Vec3 = Vec3.up,
    rate: f32 = 0,
};

pub const spin_system_name = "sandbox3d:systems.spin";

/// What each object is to the sample. The keys act on roles, not on handles a person typed.
pub const Role = enum { turntable, platter, rider, moon, frame, sheared, cube };

/// The templates, in spawn order, and the parent each is given. The platter and the rider
/// are both the turntable's children rather than one the other's, because the platter is
/// scaled flat and a child of it would be flattened too.
const layout = [_]struct { role: Role, template: []const u8, parent: ?Role }{
    .{ .role = .turntable, .template = "sandbox3d:entity.turntable", .parent = null },
    .{ .role = .platter, .template = "sandbox3d:entity.platter", .parent = .turntable },
    .{ .role = .rider, .template = "sandbox3d:entity.rider", .parent = .turntable },
    .{ .role = .moon, .template = "sandbox3d:entity.moon", .parent = .rider },
    .{ .role = .frame, .template = "sandbox3d:entity.frame", .parent = null },
    .{ .role = .sheared, .template = "sandbox3d:entity.sheared", .parent = .frame },
    .{ .role = .cube, .template = "sandbox3d:entity.cube", .parent = null },
};

const role_count = @typeInfo(Role).@"enum".fields.len;

/// A bound on a save this sample will read. Untrusted input is bounded where it enters.
pub const max_save_bytes: usize = 16 * 1024 * 1024;

pub const Orrery = struct {
    gpa: std.mem.Allocator,
    jobs: core.Jobs,
    /// The world's own registry, which it borrows, so this struct is built in place.
    schemas: data.Registry,
    world: scene.World,
    types: hierarchy.Types,
    roles: [role_count]?Entity = @splat(null),

    /// Builds an empty world with the hierarchy and the sample's two types.
    pub fn init(self: *Orrery, gpa: std.mem.Allocator, jobs: core.Jobs) !void {
        self.* = .{
            .gpa = gpa,
            .jobs = jobs,
            .schemas = undefined,
            .world = undefined,
            .types = undefined,
        };
        try self.build();
    }

    fn build(self: *Orrery) !void {
        self.schemas = .init(self.gpa, .default);
        errdefer self.schemas.deinit(self.gpa);
        self.world = .init(self.gpa, &self.schemas, .default);
        errdefer self.world.deinit();
        self.world.setJobs(self.jobs);
        // First, while the world is empty, as `enableHierarchy` insists.
        self.types = try self.world.enableHierarchy();
        _ = try self.world.registerComponent(scene.componentType(Model));
        _ = try self.world.registerComponent(scene.componentType(Spin));
        // The writer, then the propagation: registration order is run order (§4.1).
        _ = try self.world.registerSystem(.{
            .id = core.ContentId.fromString(spin_system_name),
            .name = spin_system_name,
            .update = &spinSystem,
        });
        _ = try self.world.registerSystem(hierarchy.system());
    }

    pub fn deinit(self: *Orrery) void {
        self.world.deinit();
        self.schemas.deinit(self.gpa);
    }

    /// Spawns every template the package has and parents them. A missing or refused template
    /// is logged and its role left empty; what depends on it stands on its own.
    pub fn populate(self: *Orrery, store: *const data.Store) void {
        for (layout) |item| {
            const id = core.ContentId.fromString(item.template);
            self.roles[@intFromEnum(item.role)] = self.world.spawn(store, id) catch |err| blk: {
                log.warn("'{s}' was not spawned ({t}); the orrery is without it", .{ item.template, err });
                break :blk null;
            };
        }
        for (layout) |item| {
            const child = self.role(item.role) orelse continue;
            const parent = self.role(item.parent orelse continue) orelse continue;
            hierarchy.setParent(&self.world, child, parent) catch |err|
                log.warn("'{s}' could not be parented ({t}); it stands on its own", .{ item.template, err });
        }
        self.settle();
        log.info("orrery: {d} entities, the deepest {d} below its root", .{
            self.world.entityCount(),
            if (hierarchy.lastPropagation(&self.world)) |s| s.max_depth else 0,
        });
    }

    pub fn role(self: *const Orrery, r: Role) ?Entity {
        return self.roles[@intFromEnum(r)];
    }

    /// One fixed step: the spin, then the propagation.
    pub fn step(self: *Orrery, tick: scene.Tick) void {
        self.world.update(tick);
    }

    /// World transforms brought up to date outside a step: after a spawn, a load or a
    /// re-parent, so the frame drawn next is the world as it now is.
    fn settle(self: *Orrery) void {
        _ = hierarchy.propagate(&self.world) catch |err|
            log.warn("the orrery could not be propagated ({t}); poses are last tick's", .{err});
    }

    /// Every entity's world matrix, hashed in slot order: what the log compares either side of
    /// a save and a load. Equal hashes mean equal poses, to the bit.
    pub fn poseHash(self: *const Orrery) u64 {
        var hasher = std.hash.Wyhash.init(0);
        var it = self.world.liveEntities();
        while (it.next()) |e| {
            const m = hierarchy.worldTransform(&self.world, e) orelse continue;
            hasher.update(std.mem.asBytes(&e.bits()));
            hasher.update(std.mem.asBytes(&m));
        }
        return hasher.final();
    }

    /// The world as an `.fsav`, with the poses it carries propagated first, so the hash
    /// logged beside it is of exactly what was saved.
    pub fn save(self: *Orrery, out: *std.ArrayList(u8)) !u64 {
        self.settle();
        try self.world.save(out);
        return self.poseHash();
    }

    /// Replaces the world with a save's. A save this build cannot read leaves a freshly
    /// populated orrery rather than an empty table, and says so. Returns the loaded poses'
    /// hash, or null if the save was refused.
    pub fn load(self: *Orrery, bytes: []const u8, store: *const data.Store) ?u64 {
        self.deinit();
        self.build() catch |err| {
            // Nothing is left to draw from; the process has no world at all.
            log.err("the world could not be rebuilt ({t})", .{err});
            @panic("sandbox3d: no world");
        };
        const summary = self.world.load(bytes, .default) catch |err| {
            log.warn("the save was refused ({t}); a fresh orrery instead", .{err});
            self.deinit();
            self.build() catch @panic("sandbox3d: no world");
            self.roles = @splat(null);
            self.populate(store);
            return null;
        };
        self.settle();
        // The save carries the handles this build spawned, so each role is the same entity
        // again. One that is not live, or has no pose, is not the object its key moves.
        for (&self.roles, 0..) |*slot, i| {
            const e = slot.* orelse continue;
            if (!self.world.hasComponent(e, self.types.transform)) {
                log.warn("the save has no {t}; its key does nothing until the next start", .{@as(Role, @enumFromInt(i))});
                slot.* = null;
            }
        }
        log.info("loaded {d} entities and {d} components", .{ summary.entities, summary.components });
        return self.poseHash();
    }

    pub const Hop = struct {
        from: ?Entity,
        to: Entity,
        /// The largest change in any world-matrix element across the hop.
        moved: f32,
    };

    /// F6: the orbiting crate changes parent between the riding crate and the cube, keeping
    /// its world pose. It does not jump, and `moved` is how far it did not.
    pub fn hopMoon(self: *Orrery) hierarchy.ReparentError!Hop {
        const moon = self.role(.moon) orelse return error.NoSuchEntity;
        const rider = self.role(.rider) orelse return error.NoSuchEntity;
        const cube = self.role(.cube) orelse return error.NoSuchEntity;
        const from = hierarchy.parentOf(&self.world, moon);
        const to = if (from != null and from.?.eql(rider)) cube else rider;
        return self.keepWorld(moon, from, to);
    }

    /// F7: the same for the sheared child, onto the turntable. Its world is sheared, so no
    /// transform under a rigid parent holds it: refused as `NotRepresentable`, and nothing
    /// moves.
    pub fn hopSheared(self: *Orrery) hierarchy.ReparentError!Hop {
        const sheared = self.role(.sheared) orelse return error.NoSuchEntity;
        const turntable = self.role(.turntable) orelse return error.NoSuchEntity;
        return self.keepWorld(sheared, hierarchy.parentOf(&self.world, sheared), turntable);
    }

    fn keepWorld(self: *Orrery, child: Entity, from: ?Entity, to: Entity) hierarchy.ReparentError!Hop {
        const before = hierarchy.worldOf(&self.world, child) orelse return error.NoSuchEntity;
        try hierarchy.setParentKeepWorld(&self.world, child, to);
        self.settle();
        const after = hierarchy.worldTransform(&self.world, child) orelse before;
        var moved: f32 = 0;
        for (0..4) |c| for (0..4) |r| {
            moved = @max(moved, @abs(after.cols[c][r] - before.cols[c][r]));
        };
        return .{ .from = from, .to = to, .moved = moved };
    }
};

/// Turns each spinning entity about its own axis by one step. A local pose, so its children
/// turn with it once the propagation that runs next has composed them.
fn spinSystem(_: ?*anyopaque, world: *scene.World, tick: scene.Tick) void {
    const dt = tick.delta.toSecondsF32();
    var it = world.queryOf(.{ hierarchy.Transform, Spin });
    while (it.next()) |m| {
        const spin = m.get(Spin);
        const t = m.get(hierarchy.Transform);
        // Content is untrusted: an axis of no length or a rate that is not a number leaves
        // the entity still rather than writing a pose the propagation would freeze.
        const length = spin.axis.length();
        if (!(length > 0) or !std.math.isFinite(length) or !std.math.isFinite(spin.rate)) continue;
        const turn = Quat.fromAxisAngle(spin.axis.scale(1 / length), spin.rate * dt);
        // Renormalised every step, so a long run does not drift off the unit sphere.
        t.rotation = Quat.mul(t.rotation, turn).normalize();
    }
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

fn testOrrery() !*Orrery {
    const o = try testing.allocator.create(Orrery);
    errdefer testing.allocator.destroy(o);
    try o.init(testing.allocator, core.jobs.serial);
    return o;
}

fn place(o: *Orrery, r: Role, local: core.math.Transform, model: bool) !Entity {
    const e = try o.world.create();
    const t = hierarchy.Transform.fromCore(local);
    _ = try o.world.addComponent(e, o.types.transform, std.mem.asBytes(&t));
    if (model) {
        const m: Model = .{ .model = core.ContentId.fromString("sandbox3d:models.crate") };
        _ = try o.world.addComponent(e, o.world.findComponent(scene.query.schemaIdOf(Model)).?, std.mem.asBytes(&m));
    }
    o.roles[@intFromEnum(r)] = e;
    return e;
}

/// The orrery's shape, built by hand: the tests do not have the package.
fn handBuilt(o: *Orrery) !void {
    const spin_type = o.world.findComponent(scene.query.schemaIdOf(Spin)).?;
    const turntable = try place(o, .turntable, .{ .translation = .init(-0.4, 0.78, 0) }, false);
    const rider = try place(o, .rider, .{ .translation = .init(0.18, 0.04, 0), .scale = .init(0.25, 0.25, 0.25) }, true);
    const moon = try place(o, .moon, .{ .translation = .init(1.1, 0.9, 0), .scale = .init(0.35, 0.35, 0.35) }, true);
    const frame = try place(o, .frame, .{ .translation = .init(0.45, 0.78, 0), .scale = .init(0.4, 0.2, 0.2) }, true);
    const sheared = try place(o, .sheared, .{
        .translation = .init(0, 0.8, 0),
        .rotation = Quat.fromAxisAngle(Vec3.up, std.math.pi / 4.0),
    }, true);
    const cube = try place(o, .cube, .{ .translation = .init(0.05, 1.2, -0.2), .scale = .init(0.25, 0.25, 0.25) }, false);
    for ([_]struct { Entity, f32 }{ .{ turntable, 0.5 }, .{ rider, 1.2 }, .{ cube, 0.6 } }) |pair| {
        const spin: Spin = .{ .axis = .init(0.3, 1, 0.2), .rate = pair[1] };
        _ = try o.world.addComponent(pair[0], spin_type, std.mem.asBytes(&spin));
    }
    try hierarchy.setParent(&o.world, rider, turntable);
    try hierarchy.setParent(&o.world, moon, rider);
    try hierarchy.setParent(&o.world, sheared, frame);
    o.settle();
}

fn tickAt(n: u64) scene.Tick {
    return .{ .tick = n, .delta = .fromNanos(16_666_667) };
}

test "the spin turns local poses, and the moon orbits because its parent turns" {
    const o = try testOrrery();
    defer testing.allocator.destroy(o);
    defer o.deinit();
    try handBuilt(o);
    const moon_before = hierarchy.worldTransform(&o.world, o.role(.moon).?).?;
    for (1..31) |i| o.step(tickAt(i));
    const moon_after = hierarchy.worldTransform(&o.world, o.role(.moon).?).?;
    try testing.expect(!std.mem.eql(u8, std.mem.asBytes(&moon_before), std.mem.asBytes(&moon_after)));
    // The moon has no spin of its own: its local pose is what it was, and its world moved.
    const local = std.mem.bytesToValue(hierarchy.Transform, o.world.readComponent(o.role(.moon).?, o.types.transform).?);
    try testing.expectEqual(@as(f32, 1.1), local.translation.x);
    try testing.expect(local.isValid());
    // The sheared child, which nothing spins, is still sheared.
    const sheared = hierarchy.worldTransform(&o.world, o.role(.sheared).?).?;
    try testing.expectError(error.NotRepresentable, core.math.Transform.fromMat4Exact(sheared));
}

test "the spin runs before the propagation, so a drawn pose is never a tick behind" {
    const o = try testOrrery();
    defer testing.allocator.destroy(o);
    defer o.deinit();
    try handBuilt(o);
    for (1..4) |i| {
        o.step(tickAt(i));
        // What the step left for drawing is the world the local poses now describe.
        for ([_]Role{ .turntable, .rider, .moon, .cube }) |r| {
            const drawn = hierarchy.worldTransform(&o.world, o.role(r).?).?;
            const now = hierarchy.worldOf(&o.world, o.role(r).?).?;
            try testing.expectEqualSlices(u8, std.mem.asBytes(&now), std.mem.asBytes(&drawn));
        }
    }
}

test "a saved orrery loads back to the same poses, and F6 and F7 keep their promises" {
    const o = try testOrrery();
    defer testing.allocator.destroy(o);
    defer o.deinit();
    try handBuilt(o);
    for (1..11) |i| o.step(tickAt(i));

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    const saved = try o.save(&bytes);
    for (11..41) |i| o.step(tickAt(i));
    try testing.expect(o.poseHash() != saved);

    var store: data.Store = .init(testing.allocator, .default);
    defer store.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, saved), o.load(bytes.items, &store));
    try testing.expect(o.role(.moon) != null);

    // F6: the moon changes parent and does not jump; twice brings it back to the rider.
    const first = try o.hopMoon();
    try testing.expect(first.to.eql(o.role(.cube).?));
    try testing.expect(first.moved < 1e-5);
    const second = try o.hopMoon();
    try testing.expect(second.to.eql(o.role(.rider).?));
    try testing.expect(second.moved < 1e-5);

    // F7: refused, and nothing moved.
    const before = o.poseHash();
    try testing.expectError(error.NotRepresentable, o.hopSheared());
    try testing.expectEqual(before, o.poseHash());
    try testing.expect(hierarchy.parentOf(&o.world, o.role(.sheared).?).?.eql(o.role(.frame).?));
}

test "a save this build cannot read leaves an orrery, not an empty table" {
    const o = try testOrrery();
    defer testing.allocator.destroy(o);
    defer o.deinit();
    try handBuilt(o);
    var store: data.Store = .init(testing.allocator, .default);
    defer store.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, null), o.load("not a save", &store));
    // The store has no templates, so the fresh orrery is empty, but it is a world.
    try testing.expectEqual(@as(u32, 0), o.world.entityCount());
    try testing.expect(hierarchy.enabled(&o.world));
}

test "a spin with no axis, or a rate that is not a number, leaves the entity still" {
    const o = try testOrrery();
    defer testing.allocator.destroy(o);
    defer o.deinit();
    const spin_type = o.world.findComponent(scene.query.schemaIdOf(Spin)).?;
    for ([_]Spin{ .{ .axis = .zero, .rate = 1 }, .{ .rate = std.math.nan(f32) } }) |bad| {
        const e = try place(o, .cube, .{}, false);
        _ = try o.world.addComponent(e, spin_type, std.mem.asBytes(&bad));
    }
    for (1..4) |i| o.step(tickAt(i));
    var it = o.world.queryOf(.{hierarchy.Transform});
    while (it.next()) |m| try testing.expectEqual(Quat.identity, m.get(hierarchy.Transform).rotation);
}
