//! M38's yard (`docs/design/collision-scale.md` §11): collision at scale, east of everything at
//! `sandbox3d:yard.main`'s origin and away from every tour path, so none of it moves an older pin.
//!
//! - **The hillside** is `models/yard.gltf`'s collision, 32,258 triangles, which `author` baked a
//!   tree into. It is added here, at the yard's place, with that tree: nothing builds one at load.
//! - **The stones** are 2,048 static bodies on a 64 by 32 grid. Three in four are boxes, and one in
//!   four is the boulder's hull at one of four scales. They are drawn as one runtime mesh, built
//!   once (ADR-0063).
//! - **The movers** are 64 kinematic boxes on circles in the lanes between the rows, moved by
//!   `moveBody` each tick before the player (`collision-extras.md` §13).
//! - **The boulder** stands at the end of the middle lane: its hull, at full size, with a ramp
//!   tilted 20° that the player walks up.
//!
//! The hillside's body is placed at the yard's origin, turned by `frame`, the walk's: its mesh
//! stays in its own coordinates, so its baked tree holds in the tilted tour too. Every other pose is
//! turned the same way. `height` repeats `scripts/m38/make_yard.py`'s, in `core`'s own trig.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const physics = @import("physics3d");
const render3d = @import("render3d");
const walk_mod = @import("walk.zig");
const Vec3 = core.math.Vec3;
const Quat = core.math.Quat;
const Mat4 = core.math.Mat4;
const Pose = physics.Pose;
const log = core.log.scoped(.sandbox3d);

pub const record_id = core.ContentId.fromString("sandbox3d:yard.main");

pub const max_columns = 64;
pub const max_rows = 32;
pub const max_movers = 64;
/// The hillside's half width, and the grid's pitch along a row and between rows.
pub const half: f32 = 32;
pub const column_start: f32 = -29;
pub const column_pitch: f32 = 0.8;
pub const row_pitch: f32 = 2.0;
/// A mover: a post on a circle about its place in a lane.
pub const mover_half: Vec3 = .init(0.15, 0.3, 0.15);
pub const mover_radius: f32 = 0.35;
/// Radians a second.
pub const mover_rate: f32 = 1.5;
/// Where along its lane a mover circles, by its slot: one lane holds up to three.
const mover_slots = [_]f32{ -15, 5, 15 };
/// The boulder: its ramp's low edge, about the origin, at the end of the middle lane.
pub const boulder_x: f32 = 23.5;
pub const ramp_degrees: f32 = 20;

const dt: f32 = 1.0 / 60.0;

/// What a stone's or a mover's `user` says it is, so a query can tell them apart.
pub const stone_tag: u64 = 0x5_0000_0000;
pub const mover_tag: u64 = 0x6_0000_0000;
pub fn isStone(user: u64) bool {
    return user >> 32 == stone_tag >> 32;
}
pub fn isMover(user: u64) bool {
    return user >> 32 == mover_tag >> 32;
}

/// The hillside's height about its own origin: `make_yard.py`'s three sines.
pub fn height(x: f32, z: f32) f32 {
    return 0.45 * sin(0.37 * x + 0.4) * cos(0.29 * z) +
        0.25 * sin(0.61 * (x + z) + 1.1) +
        0.15 * cos(0.83 * x - 0.47 * z);
}
fn sin(a: f32) f32 {
    return @floatCast(core.math.trig.sinCosTurns(@as(f64, a) / (2 * std.math.pi))[0]);
}
fn cos(a: f32) f32 {
    return @floatCast(core.math.trig.sinCosTurns(@as(f64, a) / (2 * std.math.pi))[1]);
}

/// A row's z about the origin, rows centred on it.
pub fn rowZ(row: u32, rows: u32) f32 {
    return (@as(f32, @floatFromInt(row)) - @as(f32, @floatFromInt(rows - 1)) / 2) * row_pitch;
}
/// The lane between row `lane` and the next.
pub fn laneZ(lane: u32, rows: u32) f32 {
    return rowZ(lane, rows) + row_pitch / 2;
}
/// The lane the tour walks, which the boulder ends: the middle one.
pub fn middleLane(rows: u32) u32 {
    return rows / 2 - 1;
}

pub const Settings = struct {
    ground: core.ContentId,
    boulder: core.ContentId,
    hull: core.ContentId,
    mover_model: core.ContentId,
    stone_material: core.ContentId,
    stone_surface: core.ContentId,
    mover_surface: core.ContentId,
    origin: Vec3,
    columns: u32,
    rows: u32,
    movers: u32,

    pub fn read(fields: data.fpk.Fields) !Settings {
        const at = (try fields.nestedAt(try index(fields, "origin"))) orelse return error.InvalidYard;
        const out: Settings = .{
            .ground = try id(fields, "ground"),
            .boulder = try id(fields, "boulder"),
            .hull = try id(fields, "hull"),
            .mover_model = try id(fields, "mover_model"),
            .stone_material = try id(fields, "stone_material"),
            .stone_surface = try id(fields, "stone_surface"),
            .mover_surface = try id(fields, "mover_surface"),
            .origin = .init(try number(at, "x"), try number(at, "y"), try number(at, "z")),
            .columns = try count(fields, "columns"),
            .rows = try count(fields, "rows"),
            .movers = try count(fields, "movers"),
        };
        // A mod thins the yard; it does not grow it past the layout, and a lane needs two rows.
        if (out.columns > max_columns or out.rows < 2 or out.rows > max_rows or out.movers > max_movers or
            out.movers > mover_slots.len * (out.rows - 1)) return error.InvalidYard;
        const reach: Vec3 = .init(half + 4, 4, half + 4);
        if (!physics.shape.positionValid(out.origin.add(reach)) or !physics.shape.positionValid(out.origin.sub(reach))) return error.InvalidYard;
        return out;
    }
};

fn index(fields: data.fpk.Fields, name: []const u8) !u32 {
    for (fields.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    return error.InvalidYard;
}
fn number(fields: data.fpk.Fields, name: []const u8) !f32 {
    const value: f32 = @floatCast((try fields.floatAt(try index(fields, name))) orelse return error.InvalidYard);
    if (!std.math.isFinite(value)) return error.InvalidYard;
    return value;
}
fn count(fields: data.fpk.Fields, name: []const u8) !u32 {
    const value = (try fields.intAt(try index(fields, name))) orelse return error.InvalidYard;
    return std.math.cast(u32, value) orelse error.InvalidYard;
}
fn id(fields: data.fpk.Fields, name: []const u8) !core.ContentId {
    const value = (try fields.idAt(try index(fields, name))) orelse return error.InvalidYard;
    if (value.isNone()) return error.InvalidYard;
    return value;
}

/// A stone, about the origin: a box or the hull at a scale, standing on the hillside.
pub const Stone = struct {
    position: Vec3,
    /// A box's half extents, or for a hull its scale in `x`.
    size: Vec3,
    hull: bool,
};

/// Stone `column`, `row`: one in four a hull, its size from a small hash of its place, sunk a
/// little into the hillside so it stands on it wherever the triangles and `height` differ.
pub fn stoneAt(column: u32, row: u32, rows: u32) Stone {
    const x = column_start + @as(f32, @floatFromInt(column)) * column_pitch;
    const z = rowZ(row, rows);
    const m = (column + max_columns * row) *% 0x9E37_79B1;
    const bits = m >> 8;
    if ((column + 3 * row) % 4 == 0) {
        const scale = 0.06 + 0.01 * @as(f32, @floatFromInt(bits & 3));
        // The hull's ramp edge is its origin; it stands centred on its place.
        return .{ .position = .init(x - 1.6 * scale, height(x, z), z), .size = .init(scale, scale, scale), .hull = true };
    }
    const size: Vec3 = .init(
        0.12 + 0.02 * @as(f32, @floatFromInt(bits & 3)),
        0.1 + 0.05 * @as(f32, @floatFromInt((bits >> 2) & 3)),
        0.12 + 0.02 * @as(f32, @floatFromInt((bits >> 4) & 3)),
    );
    return .{ .position = .init(x, height(x, z) + size.y - 0.05, z), .size = size, .hull = false };
}

/// Mover `k` at `tick`, about the origin: its lane, its slot along it, and its turn round its
/// circle, phased by `k` so they do not move as one.
pub fn moverPose(k: u32, tick: u32, rows: u32) Pose {
    const lanes = rows - 1;
    const centre_x = mover_slots[k / lanes];
    const centre_z = laneZ(k % lanes, rows);
    const ticks_a_turn: u32 = 2520; // 42 s, about 10 turns: kept small so the angle stays exact.
    const angle = mover_rate * dt * @as(f32, @floatFromInt(tick % ticks_a_turn)) + 0.7 * @as(f32, @floatFromInt(k));
    const x = centre_x + mover_radius * cos(angle);
    const z = centre_z + mover_radius * sin(angle);
    return .at(.init(x, height(x, z) + mover_half.y - 0.02, z));
}

/// The boulder's place, about the origin: its ramp's low edge on the hillside.
pub fn boulderPose() Pose {
    return .at(.init(boulder_x, height(boulder_x, 0), 0));
}

pub const Yard = struct {
    settings: ?Settings = null,
    /// The walk's frame: identity, or the tilted tour's turn.
    frame: Quat = .identity,
    /// The movers' own clock, in ticks, which the tour sets back to begin.
    tick: u32 = 0,
    ground_asset: asset.AssetHandle = .none,
    ground_mesh: physics.MeshHandle = .none,
    ground: physics.BodyHandle = .none,
    hull_asset: asset.AssetHandle = .none,
    hull: physics.HullHandle = .none,
    /// The hull's points, borrowed from its asset while the yard holds it.
    hull_points: []const Vec3 = &.{},
    boulder: physics.BodyHandle = .none,
    stones: std.ArrayList(physics.BodyHandle) = .empty,
    movers: std.ArrayList(physics.BodyHandle) = .empty,
    /// Characters the movers pushed on the last tick, and what their moves cost, when `step`
    /// was given a clock. Measurement only.
    pushed: u32 = 0,
    movers_ns: ?i64 = null,
    /// How long the hillside took to join the world with its tree, and without, when `refresh`
    /// was given a clock. Measurement only.
    baked_ns: ?i64 = null,
    built_ns: ?i64 = null,
    triangles: usize = 0,
    /// What draws it, when there is a renderer.
    ground_model: render3d.ModelHandle = .none,
    boulder_model: render3d.ModelHandle = .none,
    mover_model: render3d.ModelHandle = .none,
    stone_mesh: render3d.MeshHandle = .none,
    stone_material: render3d.MaterialHandle = .none,
    reported: bool = false,

    pub fn deinit(self: *Yard, gpa: std.mem.Allocator, world: *physics.World, assets: *asset.Registry, content: ?*render3d.Content) void {
        for (self.movers.items) |b| _ = world.removeBody(gpa, b);
        for (self.stones.items) |b| _ = world.removeBody(gpa, b);
        self.movers.deinit(gpa);
        self.stones.deinit(gpa);
        for ([_]physics.BodyHandle{ self.boulder, self.ground }) |b| {
            if (!b.isNone()) _ = world.removeBody(gpa, b);
        }
        if (!self.hull.isNone()) _ = world.removeHull(gpa, self.hull) catch unreachable; // Its bodies went above.
        if (!self.ground_mesh.isNone()) _ = world.removeMesh(gpa, self.ground_mesh) catch unreachable; // So did the hillside's.
        if (!self.hull_asset.isNone()) assets.release(self.hull_asset);
        if (!self.ground_asset.isNone()) assets.release(self.ground_asset);
        if (content) |c| {
            for ([_]render3d.ModelHandle{ self.ground_model, self.boulder_model, self.mover_model }) |m| {
                if (!m.isNone()) c.releaseModel(m);
            }
            if (!self.stone_mesh.isNone()) c.renderer.destroyMesh(self.stone_mesh);
            if (!self.stone_material.isNone()) c.releaseMaterial(self.stone_material);
        }
        const frame = self.frame;
        self.* = .{ .frame = frame };
    }

    /// Made again at every content refresh, from `sandbox3d:yard.main`; without the record, or
    /// with one that will not do, there is no yard, and nothing else changes. `clock`, null or
    /// anything with `monotonicNanos`, times the hillside joining the world, once.
    pub fn refresh(self: *Yard, gpa: std.mem.Allocator, store: *const data.Store, world: *physics.World, assets: *asset.Registry, content: ?*render3d.Content, clock: anytype) void {
        self.deinit(gpa, world, assets, content);
        const record = store.lookup(record_id) orelse return;
        const settings = Settings.read(record.fields) catch |err| {
            log.warn("the M38 yard is left out ({t})", .{err});
            return;
        };
        self.build(gpa, store, world, assets, settings, clock) catch |err| {
            log.warn("the M38 yard is left out ({t})", .{err});
            self.deinit(gpa, world, assets, content);
            return;
        };
        self.settings = settings;
        if (content) |c| self.prepareDrawing(gpa, c, world, settings) catch |err| {
            log.warn("the M38 yard is not drawn ({t})", .{err});
        };
    }

    fn build(self: *Yard, gpa: std.mem.Allocator, store: *const data.Store, world: *physics.World, assets: *asset.Registry, s: Settings, clock: anytype) !void {
        // The hillside: whatever collision its model names, with the tree baked into it.
        const model = store.lookup(s.ground) orelse return error.MissingGround;
        const at = model.schema.fieldIndex("collision") orelse return error.GroundNamesNoCollision;
        const collision = (try model.fields.idAt(at)) orelse return error.GroundNamesNoCollision;
        const kind = store.lookup(collision) orelse return error.MissingGroundCollision;
        if (!kind.schema.id.eql(asset.schemas.collision_mesh.id)) return error.WrongKind;
        self.ground_asset = try assets.acquire(gpa, collision);
        const product = assets.getIfLoader(self.ground_asset, asset.collisionMeshLoader()) orelse return error.WrongLoader;
        const geometry = asset.collision_mesh.fromPayload(product.payload);
        self.triangles = geometry.indices.len / 3;
        const timed = @TypeOf(clock) != @TypeOf(null);
        const started = if (timed) clock.monotonicNanos() else 0; // Measurement only.
        self.ground_mesh = try walk_mod.addCollisionMesh(gpa, world, geometry, .identity);
        if (timed) {
            self.baked_ns = @intCast(clock.monotonicNanos() - started);
            // The same mesh built at load, beside it, once, and taken away again.
            var bare = geometry.*;
            bare.tree_nodes = &.{};
            bare.tree_order = &.{};
            const again = clock.monotonicNanos();
            const built = try walk_mod.addCollisionMesh(gpa, world, &bare, .identity);
            self.built_ns = @intCast(clock.monotonicNanos() - again);
            _ = world.removeMesh(gpa, built) catch unreachable; // No body names it.
        }
        self.ground = try world.addBody(gpa, .{ .shape = .{ .mesh = self.ground_mesh }, .pose = self.place(.at(.zero), s), .user = s.ground.hash });

        // The boulder's hull, shared by the boulder and one stone in four at their scales.
        const hull_record = store.lookup(s.hull) orelse return error.MissingHull;
        if (!hull_record.schema.id.eql(asset.schemas.collision_hull.id)) return error.WrongKind;
        self.hull_asset = try assets.acquire(gpa, s.hull);
        const hull_product = assets.getIfLoader(self.hull_asset, asset.collisionHullLoader()) orelse return error.WrongLoader;
        const points = asset.collision_hull.fromPayload(hull_product.payload).points;
        self.hull = try world.addHull(gpa, points);
        self.hull_points = points;
        self.boulder = try world.addBody(gpa, .{ .shape = .{ .hull = self.hull }, .pose = self.place(boulderPose(), s), .surface = s.stone_surface, .user = s.boulder.hash });

        try self.stones.ensureTotalCapacity(gpa, s.columns * s.rows);
        for (0..s.rows) |row| for (0..s.columns) |column| {
            const stone = stoneAt(@intCast(column), @intCast(row), s.rows);
            const k: u64 = self.stones.items.len;
            const body = if (stone.hull)
                try world.addBody(gpa, .{ .shape = .{ .hull = self.hull }, .pose = self.place(.at(stone.position), s), .scale = stone.size, .surface = s.stone_surface, .user = stone_tag | k })
            else
                try world.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = stone.size } }, .pose = self.place(.at(stone.position), s), .surface = s.stone_surface, .user = stone_tag | k });
            self.stones.appendAssumeCapacity(body);
        };
        try self.movers.ensureTotalCapacity(gpa, s.movers);
        for (0..s.movers) |k| {
            const body = try world.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = mover_half } }, .pose = self.place(moverPose(@intCast(k), 0, s.rows), s), .kind = .kinematic, .surface = s.mover_surface, .user = mover_tag | k });
            self.movers.appendAssumeCapacity(body);
        }
        self.tick = 0;
    }

    /// The yard's start, as the tour begins: the movers set back to `tick`. `setPose` pushes
    /// nobody.
    pub fn reset(self: *Yard, gpa: std.mem.Allocator, world: *physics.World, tick: u32) !void {
        const s = self.settings orelse return error.NoYard;
        self.tick = tick;
        for (self.movers.items, 0..) |b, k| _ = try world.setPose(gpa, b, self.place(moverPose(@intCast(k), tick, s.rows), s));
    }

    /// §13's first step: the movers, before any character moves. `clock`, null or anything with
    /// `monotonicNanos`, times them together and nothing else.
    pub fn step(self: *Yard, gpa: std.mem.Allocator, world: *physics.World, clock: anytype) !void {
        self.movers_ns = null;
        self.pushed = 0;
        const s = self.settings orelse return;
        self.tick +%= 1;
        var crushed: [4]physics.CharacterHandle = undefined;
        const started = if (@TypeOf(clock) == @TypeOf(null)) 0 else clock.monotonicNanos(); // Measurement only.
        for (self.movers.items, 0..) |b, k| {
            const moved = try world.moveBody(gpa, b, self.place(moverPose(@intCast(k), self.tick, s.rows), s), &crushed);
            if (moved) |m| self.pushed += m.pushed;
        }
        if (@TypeOf(clock) != @TypeOf(null)) self.movers_ns = @intCast(clock.monotonicNanos() - started);
    }

    /// A pose about the yard's origin, in the upright frame, turned into the walk world's.
    pub fn place(self: *const Yard, pose: Pose, s: Settings) Pose {
        return .{ .position = self.frame.rotate(pose.position.add(s.origin)), .rotation = self.frame.mul(pose.rotation) };
    }
    /// A point about the yard's origin, in the upright frame.
    pub fn point(self: *const Yard, local: Vec3) Vec3 {
        return local.add(self.settings.?.origin);
    }

    fn prepareDrawing(self: *Yard, gpa: std.mem.Allocator, content: *render3d.Content, world: *physics.World, s: Settings) !void {
        self.ground_model = acquire(content, s.ground);
        self.boulder_model = acquire(content, s.boulder);
        self.mover_model = acquire(content, s.mover_model);
        self.stone_material = try content.acquireMaterial(s.stone_material);
        var mesh = try self.stoneMesh(gpa, world);
        defer mesh.deinit(gpa);
        self.stone_mesh = try content.renderer.createMesh(mesh.mesh, "sandbox3d stones");
    }

    fn acquire(content: *render3d.Content, model: core.ContentId) render3d.ModelHandle {
        return content.acquireModel(model) catch |err| blk: {
            log.warn("model {f} is not drawn ({t})", .{ model, err });
            break :blk .none;
        };
    }

    /// Every stone in one mesh, in the walk world's coordinates: a box's six faces, or each of
    /// the hull's faces fanned from its corners, which `physics3d` found from its points.
    pub fn stoneMesh(self: *const Yard, gpa: std.mem.Allocator, world: *physics.World) !asset.OwnedMesh {
        var positions: std.ArrayList(Vec3) = .empty;
        defer positions.deinit(gpa);
        var normals: std.ArrayList(Vec3) = .empty;
        defer normals.deinit(gpa);
        var indices: std.ArrayList(u32) = .empty;
        defer indices.deinit(gpa);
        // The hull's faces as polygons, once, about its own origin.
        var outline: std.ArrayList(Vec3) = .empty;
        defer outline.deinit(gpa);
        var outline_normals: std.ArrayList(Vec3) = .empty;
        defer outline_normals.deinit(gpa);
        var fans: std.ArrayList(u32) = .empty;
        defer fans.deinit(gpa);
        try hullOutline(gpa, self.hull_points, world.hullFaces(self.hull).?, &outline, &outline_normals, &fans);
        for (self.stones.items) |b| {
            const body = world.body(b).?;
            const base: u32 = @intCast(positions.items.len);
            switch (body.shape) {
                .box => |box| {
                    try boxFaces(gpa, box.half_extents, &positions, &normals, &indices);
                },
                .hull => {
                    for (outline.items, outline_normals.items) |p, n| {
                        try positions.append(gpa, p.mul(body.scale));
                        try normals.append(gpa, n);
                    }
                    for (fans.items) |i| try indices.append(gpa, base + i);
                },
                else => unreachable,
            }
            for (positions.items[base..], normals.items[base..]) |*p, *n| {
                p.* = body.pose.apply(p.*);
                n.* = body.pose.rotation.rotate(n.*);
            }
        }
        var builder: asset.MeshBuilder = .init(gpa, .{});
        defer builder.deinit();
        try builder.positions(positions.items);
        try builder.normals(normals.items);
        try builder.indices32(indices.items);
        return builder.finish();
    }

    pub fn draw(self: *Yard, world: *physics.World, content: *render3d.Content) void {
        const s = self.settings orelse return;
        const ground = world.body(self.ground).?.pose;
        self.drawOne(content, self.ground_model, Mat4.trs(ground.position, ground.rotation, .one));
        const boulder = world.body(self.boulder).?.pose;
        self.drawOne(content, self.boulder_model, Mat4.trs(boulder.position, boulder.rotation, .one));
        // The mover model is the crate's: 0.8 m a side, standing on its origin.
        for (self.movers.items) |b| {
            const pose = world.body(b).?.pose;
            const foot = pose.position.add(pose.rotation.rotate(.init(0, -mover_half.y, 0)));
            self.drawOne(content, self.mover_model, Mat4.trs(foot, pose.rotation, mover_half.scale(1.0 / 0.4)));
        }
        _ = s;
        if (!self.stone_mesh.isNone() and !self.stone_material.isNone()) {
            content.renderer.drawMesh(.{ .mesh = self.stone_mesh, .material = self.stone_material, .world = .identity }) catch |err| {
                if (!self.reported) log.warn("the M38 stones are not drawn ({t})", .{err});
                self.reported = true;
            };
        }
    }
    fn drawOne(self: *Yard, content: *render3d.Content, model: render3d.ModelHandle, matrix: Mat4) void {
        if (model.isNone()) return;
        content.drawModel(.{ .model = model, .world = matrix }) catch |err| {
            if (!self.reported) log.warn("an M38 yard piece is not drawn ({t})", .{err});
            self.reported = true;
        };
    }
};

/// A box's six faces about its centre, four corners each, counter-clockwise from outside.
fn boxFaces(gpa: std.mem.Allocator, h: Vec3, positions: *std.ArrayList(Vec3), normals: *std.ArrayList(Vec3), indices: *std.ArrayList(u32)) !void {
    const faces = [_][3]Vec3{
        .{ .init(1, 0, 0), .init(0, 0, -1), .init(0, 1, 0) },
        .{ .init(-1, 0, 0), .init(0, 0, 1), .init(0, 1, 0) },
        .{ .init(0, 1, 0), .init(1, 0, 0), .init(0, 0, -1) },
        .{ .init(0, -1, 0), .init(1, 0, 0), .init(0, 0, 1) },
        .{ .init(0, 0, 1), .init(1, 0, 0), .init(0, 1, 0) },
        .{ .init(0, 0, -1), .init(-1, 0, 0), .init(0, 1, 0) },
    };
    for (faces) |f| {
        const base: u32 = @intCast(positions.items.len);
        for ([_][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } }) |c| {
            try positions.append(gpa, f[0].add(f[1].scale(c[0])).add(f[2].scale(c[1])).mul(h));
            try normals.append(gpa, f[0]);
        }
        try indices.appendSlice(gpa, &.{ base, base + 1, base + 2, base, base + 2, base + 3 });
    }
}

/// Each of a hull's faces as a polygon: the points on its plane, ordered round their centre
/// counter-clockwise from outside, and the triangles that fan it. Drawing only.
fn hullOutline(gpa: std.mem.Allocator, points: []const Vec3, planes: []const physics.HullPlane, outline: *std.ArrayList(Vec3), normals: *std.ArrayList(Vec3), fans: *std.ArrayList(u32)) !void {
    var lo = points[0];
    var hi = points[0];
    for (points) |p| {
        lo = .init(@min(lo.x, p.x), @min(lo.y, p.y), @min(lo.z, p.z));
        hi = .init(@max(hi.x, p.x), @max(hi.y, p.y), @max(hi.z, p.z));
    }
    const tolerance = 1e-4 * hi.sub(lo).length();
    var on: std.ArrayList(Vec3) = .empty;
    defer on.deinit(gpa);
    for (planes) |plane| {
        on.clearRetainingCapacity();
        for (points) |p| {
            if (@abs(plane.normal.dot(p) - plane.offset) > tolerance) continue;
            for (on.items) |q| {
                if (q.sub(p).length() <= tolerance) break;
            } else try on.append(gpa, p);
        }
        if (on.items.len < 3) continue;
        var centre: Vec3 = .zero;
        for (on.items) |p| centre = centre.add(p);
        centre = centre.scale(1 / @as(f32, @floatFromInt(on.items.len)));
        const e1 = on.items[0].sub(centre).normalize();
        const e2 = plane.normal.cross(e1);
        const Order = struct {
            centre: Vec3,
            e1: Vec3,
            e2: Vec3,
            fn angle(o: @This(), p: Vec3) f32 {
                const d = p.sub(o.centre);
                return std.math.atan2(d.dot(o.e2), d.dot(o.e1));
            }
            fn less(o: @This(), a: Vec3, b: Vec3) bool {
                return o.angle(a) < o.angle(b);
            }
        };
        std.mem.sort(Vec3, on.items, Order{ .centre = centre, .e1 = e1, .e2 = e2 }, Order.less);
        const base: u32 = @intCast(outline.items.len);
        for (on.items) |p| {
            try outline.append(gpa, p);
            try normals.append(gpa, plane.normal);
        }
        for (1..on.items.len - 1) |k| try fans.appendSlice(gpa, &.{ base, base + @as(u32, @intCast(k)), base + @as(u32, @intCast(k + 1)) });
    }
}
