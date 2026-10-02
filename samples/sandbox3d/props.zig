//! M25 Tier 1 props: enumerate sample-owned records, acquire models, copy static collision.
//! No ABI, native code, runtime geometry or borrowed payload surviving refresh (ADR-0057).
const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const physics = @import("physics3d");
const render3d = @import("render3d");
const Walk = @import("walk.zig").Walk;
const Vec3 = core.math.Vec3;
const Mat4 = core.math.Mat4;
const Quat = core.math.Quat;
const log = core.log.scoped(.sandbox3d);

pub const Settings = struct {
    model: core.ContentId,
    position: Vec3,
    yaw: f32,
    scale: f32,
    collision: core.ContentId,

    pub fn read(fields: data.fpk.Fields) !Settings {
        const position = (try fields.nestedAt(try index(fields, "position"))) orelse return error.InvalidProp;
        const out: Settings = .{
            .model = (try fields.idAt(try index(fields, "model"))) orelse return error.InvalidProp,
            .position = .init(try number(position, "x"), try number(position, "y"), try number(position, "z")),
            .yaw = try number(fields, "yaw"),
            .scale = try number(fields, "scale"),
            .collision = (try fields.idAt(try index(fields, "collision"))) orelse .none,
        };
        if (out.model.isNone() or !physics.shape.positionValid(out.position) or
            @abs(out.yaw) > 2 * std.math.pi or out.scale <= 0 or out.scale > 100) return error.InvalidProp;
        // Collision poses are rigid, never silently drawn at a different scale (ADR-0057).
        if (!out.collision.isNone() and out.scale != 1) return error.ScaledCollision;
        return out;
    }
    pub fn rotation(self: Settings) Quat {
        return Quat.fromAxisAngle(.up, self.yaw);
    }
    pub fn matrix(self: Settings) Mat4 {
        return Mat4.trs(self.position, self.rotation(), .init(self.scale, self.scale, self.scale));
    }
};
fn index(fields: data.fpk.Fields, name: []const u8) !u32 {
    for (fields.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    return error.InvalidProp;
}
fn number(fields: data.fpk.Fields, name: []const u8) !f32 {
    const value: f32 = @floatCast((try fields.floatAt(try index(fields, name))) orelse return error.InvalidProp);
    if (!std.math.isFinite(value)) return error.InvalidProp;
    return value;
}

pub const Props = struct {
    pub const max_props = 256;
    pub const schema_id = data.SchemaId.parse("sandbox3d:prop") catch unreachable;
    pub const plinth_id = core.ContentId.fromString("plinth:props.main");
    entries: [max_props]Entry = undefined,
    len: usize = 0,
    rejected: usize = 0,
    const Entry = struct {
        id: core.ContentId,
        settings: Settings,
        model: render3d.ModelHandle = .none,
        asset_handle: asset.AssetHandle = .none,
        mesh: physics.MeshHandle = .none,
        body: physics.BodyHandle = .none,
        submitted: bool = false,
        reported: bool = false,
    };

    pub fn deinit(self: *Props, gpa: std.mem.Allocator, world: *physics.World, content: *render3d.Content, assets: *asset.Registry) void {
        for (self.entries[0..self.len]) |*entry| release(entry, gpa, world, content, assets);
        self.len = 0;
    }
    fn release(entry: *Entry, gpa: std.mem.Allocator, world: *physics.World, content: *render3d.Content, assets: *asset.Registry) void {
        if (!entry.body.isNone()) _ = world.removeBody(gpa, entry.body);
        if (!entry.mesh.isNone()) _ = world.removeMesh(gpa, entry.mesh) catch unreachable; // Sole body retired above.
        if (!entry.asset_handle.isNone()) assets.release(entry.asset_handle);
        if (!entry.model.isNone()) content.releaseModel(entry.model);
    }
    /// Replace at the content-generation seam. No old or partially loaded prop survives a
    /// refusal; unchanged player/walker state belongs to their own followers, not this set.
    pub fn refresh(self: *Props, gpa: std.mem.Allocator, store: *const data.Store, world: *physics.World, content: *render3d.Content, assets: *asset.Registry) !void {
        self.deinit(gpa, world, content, assets);
        self.rejected = 0;
        var ids: [max_props]core.ContentId = undefined;
        var len: usize = 0;
        var records = store.iterate(schema_id);
        while (records.next()) |record| {
            if (len == ids.len) return error.TooManyProps;
            ids[len] = record.id;
            len += 1;
        }
        std.mem.sort(core.ContentId, ids[0..len], {}, lessThan);
        for (ids[0..len]) |id| {
            const entry = load(gpa, store, store.lookup(id).?, world, content, assets) catch |err| {
                self.rejected += 1;
                log.warn("prop {f} omitted ({t})", .{ id, err });
                continue;
            };
            self.entries[self.len] = entry;
            self.len += 1;
        }
    }
    fn lessThan(_: void, a: core.ContentId, b: core.ContentId) bool {
        return a.hash < b.hash;
    }
    fn load(gpa: std.mem.Allocator, store: *const data.Store, record: data.store.Record, world: *physics.World, content: *render3d.Content, assets: *asset.Registry) !Entry {
        var entry: Entry = .{ .id = record.id, .settings = try Settings.read(record.fields) };
        errdefer release(&entry, gpa, world, content, assets);
        entry.model = try content.acquireModel(entry.settings.model);
        if (content.isSkinned(entry.model)) return error.Unsupported;
        if (!entry.settings.collision.isNone()) {
            const collision = store.lookup(entry.settings.collision) orelse return error.MissingCollision;
            if (!collision.schema.id.eql(asset.schemas.collision_mesh.id)) return error.WrongKind;
            entry.asset_handle = try assets.acquire(gpa, entry.settings.collision);
            const product = assets.getIfLoader(entry.asset_handle, asset.collisionMeshLoader()) orelse return error.WrongLoader;
            const geometry = asset.collision_mesh.fromPayload(product.payload);
            entry.mesh = try world.addMesh(gpa, geometry.positions, geometry.indices);
            entry.body = try world.addBody(gpa, .{
                .shape = .{ .mesh = entry.mesh },
                .pose = .{ .position = entry.settings.position, .rotation = entry.settings.rotation() },
                .kind = .static,
                .user = record.id.hash,
            });
        }
        return entry;
    }
    pub fn draw(self: *Props, content: *render3d.Content) !void {
        for (self.entries[0..self.len]) |*entry| {
            const before = content.renderer.draws.items.len;
            content.drawModel(.{ .model = entry.model, .world = entry.settings.matrix() }) catch |err| switch (err) {
                error.InvalidModel, error.InvalidMesh, error.InvalidMaterial, error.MissingSkin, error.SkeletonMismatch, error.InvalidSkinCount, error.InvalidSkinMatrix => {
                    if (!entry.reported) log.warn("prop {f} not drawn ({t})", .{ entry.id, err });
                    entry.reported = true;
                    continue;
                },
                else => return err,
            };
            entry.submitted = entry.submitted or content.renderer.draws.items.len > before;
        }
    }
    pub fn plinthSelected(store: *const data.Store) bool {
        return store.lookup(plinth_id) != null;
    }
    /// Sample-specific proof, only when the content mod is selected. Ordinary drawing and
    /// collision above know no package names. Uses the actual player's ordinary step path.
    pub fn provePlinth(self: *const Props, walk: *Walk, dt: f32) !void {
        const entry = for (self.entries[0..self.len]) |*e| {
            if (e.id.eql(plinth_id)) break e;
        } else return error.MissingPlinth;
        if (!entry.submitted or entry.body.isNone()) return error.PlinthNotDrawn;
        const centre = entry.settings.position;
        const rotation = entry.settings.rotation();
        const forward = rotation.rotate(.forward);
        const start = centre.add(rotation.rotate(.init(0, physics.contact_skin, 1.05)));
        const player = walk.world.character(walk.character) orelse return error.NoCharacter;
        const hit = (try walk.world.shapeCast(.{ .capsule = .{ .radius = 0.3, .half_height = 0.6 } }, .at(start.add(.init(0, 0.95, 0))), forward.scale(1), .{ .ignore = player.body, .mask = ~@as(u32, 2) })) orelse return error.PlinthNotSolid;
        if (!hit.body.eql(entry.body)) return error.PlinthNotSolid;
        try walk.teleport(start);
        walk.yaw = entry.settings.yaw;
        var blocked = false;
        for (0..120) |_| {
            const before = walk.result.feet;
            try walk.step(.{ .direction = .forward }, dt);
            // A refused step against the base can stop motion without incrementing walls.
            blocked = blocked or walk.result.feet.sub(before).dot(forward) < walk.settings.?.walk_speed * dt * 0.25;
        }
        const advanced = walk.result.feet.sub(start).dot(forward);
        if (!blocked or walk.result.stuck or advanced < 0.1 or advanced > 1.1) {
            log.warn("plinth proof: blocked {}, stuck {}, advance {d:.4}, feet {d:.4},{d:.4},{d:.4}", .{ blocked, walk.result.stuck, advanced, walk.result.feet.x, walk.result.feet.y, walk.result.feet.z });
            return error.PlinthNotSolid;
        }
        // Subsequent tour frames face the solid prop, rather than looking over its cap.
        walk.pitch = -0.6;
        log.info("tour: plinth pass (submitted model, mesh cast, player blocked after {d:.4}m)", .{advanced});
    }
};
