//! M25 public3d.md §5–§9: validation, ownership, one subsystem operation, result.
const std = @import("std");
const core = @import("core");
const scene = @import("scene");
const physics = @import("physics3d");
const render = @import("render3d");
const types = @import("types.zig");
const d3 = @import("public3d_types.zig");
const Result = types.Result;
pub const max_hits: u32 = 4096;

fn vec(v: d3.Vec3) core.math.Vec3 {
    return @bitCast(v);
}
fn quat(q: d3.Quat) core.math.Quat {
    return @bitCast(q);
}
fn matrix(m: d3.Mat4) core.math.Mat4 {
    return @bitCast(m);
}
fn affine(m: d3.Mat4) bool {
    for (m.elements) |v| if (!std.math.isFinite(v)) return false;
    return m.elements[3] == 0 and m.elements[7] == 0 and m.elements[11] == 0 and m.elements[15] == 1;
}
fn pose(p: d3.Pose3D) ?physics.Pose {
    if (!vec(p.position).isFinite() or !quat(p.rotation).isUnit()) return null;
    return .{ .position = vec(p.position), .rotation = quat(p.rotation) };
}
fn shape(s: d3.Shape3D) ?physics.Shape {
    // Check unused floats too: a NaN in a dormant union member is still untrusted input.
    if (!std.math.isFinite(s.radius) or !std.math.isFinite(s.half_height) or !vec(s.half_extents).isFinite()) return null;
    const zero_extents = s.half_extents.x == 0 and s.half_extents.y == 0 and s.half_extents.z == 0;
    const result: physics.Shape = switch (s.kind) {
        0 => if (s.half_height == 0 and zero_extents) .{ .sphere = .{ .radius = s.radius } } else return null,
        1 => if (zero_extents) .{ .capsule = .{ .radius = s.radius, .half_height = s.half_height } } else return null,
        2 => if (s.radius == 0 and s.half_height == 0) .{ .box = .{ .half_extents = vec(s.half_extents) } } else return null,
        else => return null,
    };
    return if (result.dimensionsValid()) result else null;
}
fn shapeOut(s: physics.Shape) ?d3.Shape3D {
    var result = std.mem.zeroes(d3.Shape3D);
    switch (s) {
        .sphere => |v| {
            result.kind = 0;
            result.radius = v.radius;
        },
        .capsule => |v| {
            result.kind = 1;
            result.radius = v.radius;
            result.half_height = v.half_height;
        },
        .box => |v| {
            result.kind = 2;
            result.half_extents = @bitCast(v.half_extents);
        },
        else => return null,
    }
    return result;
}
fn filter(f: d3.Filter3D) ?physics.Filter {
    if (f.reserved != 0) return null;
    return .{ .mask = f.mask, .ignore = if (f.ignore.isNone()) null else f.ignore.unwrap(physics.BodyHandle) };
}
fn light(l: d3.Light3D) ?render.Light {
    if (!vec(l.position).isFinite() or !quat(l.rotation).isUnit() or l.casts_shadow != 0) return null;
    for (l.reserved) |v| if (v != 0) return null;
    const result: render.Light = .{
        .kind = switch (l.kind) {
            0 => .directional,
            1 => .point,
            2 => .spot,
            else => return null,
        },
        .color = .{ l.color.x, l.color.y, l.color.z },
        .intensity = l.intensity,
        .range = l.range,
        .inner_cone = l.inner_cone,
        .outer_cone = l.outer_cone,
        .world = (core.math.Transform{ .translation = vec(l.position), .rotation = quat(l.rotation).normalize() }).toMat4(),
    };
    return if (render.lighting.valid(result)) result else null;
}
fn failure(err: anyerror) Result {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidHandle, error.NoSuchEntity => .invalid_handle,
        error.WouldCycle, error.NotRepresentable, error.SingularParent => .refused,
        error.TooDeep, error.TooManyInstances, error.TooManyLights, error.TooManyOverrides, error.EntityLimit => .limit,
        error.Unsupported => .unsupported,
        error.NotFound, error.ModelNotFound, error.MaterialNotFound => .not_found,
        error.InvalidLight, error.InvalidShadowCaster, error.InvalidTransform, error.InvalidOverride, error.InvalidShape, error.InvalidPose, error.InvalidQuery, error.InvalidCharacter, error.InvalidMove, error.NotAModel, error.NotAMaterial, error.InvalidModelRecord, error.InvalidModel, error.InvalidMaterial => .invalid_argument,
        else => blk: {
            core.log.scoped(.abi).warn("unmapped public 3D ABI error: {s}", .{@errorName(err)});
            break :blk .internal;
        },
    };
}
fn hitOut(comptime T: type, value: anytype) T {
    var result = std.mem.zeroes(T);
    if (T == d3.RayHit3D) result.distance = value.distance else result.fraction = value.fraction;
    result.point = @bitCast(value.point);
    result.normal = @bitCast(value.normal);
    result.surface_normal = @bitCast(value.surface_normal);
    result.body = .wrap(value.body);
    result.user = value.user;
    result.triangle = value.triangle;
    result.started_inside = types.boolOut(value.started_inside);
    return result;
}
pub fn Of(comptime H: type) type {
    return struct {
        fn creator(h: *H, self: types.Mod) Result {
            if (h.modId(self) == null) return .invalid_handle;
            const caller = h.caller() orelse return .refused;
            return if (caller.eql(self)) .ok else .refused;
        }
        fn owner(h: *H, tag: ?u64) Result {
            const actual = tag orelse return .invalid_handle;
            const caller = h.caller() orelse return .refused;
            return if (actual == caller.bits) .ok else .refused;
        }
        fn bodyOwner(h: *H, body: d3.Body3D) Result {
            const w = h.collision3d orelse return .unavailable;
            if (w.body(body.unwrap(physics.BodyHandle)) == null) return .invalid_handle;
            // Character backing bodies cannot bypass controller invariants, even by their owner.
            for (h.characters3d) |entry| {
                if (w.character(entry.handle.unwrap(physics.CharacterHandle))) |c| {
                    if (c.body.bits() == body.bits) return .refused;
                }
            }
            for (h.bodies3d) |entry| if (entry.handle.eql(body)) return owner(h, entry.owner.bits);
            return .refused;
        }
        fn characterOwner(h: *H, c: d3.Character) Result {
            const w = h.collision3d orelse return .unavailable;
            const value = w.character(c.unwrap(physics.CharacterHandle)) orelse return .invalid_handle;
            if (w.body(value.body) == null) return .invalid_handle;
            for (h.characters3d) |entry| if (entry.handle.eql(c)) return owner(h, entry.owner.bits);
            return .refused;
        }
        pub fn render3dInstanceCreate(self: types.Mod, model: types.ContentId, world: ?*const d3.Mat4, out: ?*d3.Instance) callconv(.c) Result {
            const m = world orelse return .invalid_argument;
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const set = h.render3d_instances orelse return .unavailable;
            const content = h.render3d_content orelse return .unavailable;
            if (!affine(m.*) or model.isNone()) return .invalid_argument;
            const status = creator(h, self);
            if (status != .ok) return status;
            const handle = set.create(content, self.bits, model, matrix(m.*)) catch |err| return failure(err);
            dst.* = .wrap(handle);
            return .ok;
        }
        pub fn render3dInstanceDestroy(instance: d3.Instance) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const set = h.render3d_instances orelse return .unavailable;
            const content = h.render3d_content orelse return .unavailable;
            const status = owner(h, set.instanceOwner(instance.unwrap(render.InstanceHandle)));
            if (status != .ok) return status;
            set.destroy(content, instance.unwrap(render.InstanceHandle)) catch |err| return failure(err);
            return .ok;
        }
        pub fn render3dInstanceSetWorld(instance: d3.Instance, world: ?*const d3.Mat4) callconv(.c) Result {
            const m = world orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const set = h.render3d_instances orelse return .unavailable;
            if (!affine(m.*)) return .invalid_argument;
            const status = owner(h, set.instanceOwner(instance.unwrap(render.InstanceHandle)));
            if (status != .ok) return status;
            set.setWorld(instance.unwrap(render.InstanceHandle), matrix(m.*)) catch |err| return failure(err);
            return .ok;
        }
        pub fn render3dInstanceSetMaterial(instance: d3.Instance, slot: u32, material: types.ContentId) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const set = h.render3d_instances orelse return .unavailable;
            const content = h.render3d_content orelse return .unavailable;
            const status = owner(h, set.instanceOwner(instance.unwrap(render.InstanceHandle)));
            if (status != .ok) return status;
            set.setMaterial(content, instance.unwrap(render.InstanceHandle), slot, if (material.isNone()) null else material) catch |err| return failure(err);
            return .ok;
        }
        pub fn render3dInstanceSetVisible(instance: d3.Instance, visible: types.Bool) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const set = h.render3d_instances orelse return .unavailable;
            const status = owner(h, set.instanceOwner(instance.unwrap(render.InstanceHandle)));
            if (status != .ok) return status;
            set.setVisible(instance.unwrap(render.InstanceHandle), types.boolIn(visible)) catch |err| return failure(err);
            return .ok;
        }
        pub fn render3dLightCreate(self: types.Mod, value: ?*const d3.Light3D, out: ?*d3.Light) callconv(.c) Result {
            const v = value orelse return .invalid_argument;
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const set = h.render3d_instances orelse return .unavailable;
            const l = light(v.*) orelse return .invalid_argument;
            const status = creator(h, self);
            if (status != .ok) return status;
            dst.* = .wrap(set.createLight(self.bits, l) catch |err| return failure(err));
            return .ok;
        }
        pub fn render3dLightSet(handle: d3.Light, value: ?*const d3.Light3D) callconv(.c) Result {
            const v = value orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const set = h.render3d_instances orelse return .unavailable;
            const l = light(v.*) orelse return .invalid_argument;
            const status = owner(h, set.lightOwner(handle.unwrap(render.InstanceLightHandle)));
            if (status != .ok) return status;
            set.setLight(handle.unwrap(render.InstanceLightHandle), l) catch |err| return failure(err);
            return .ok;
        }
        pub fn render3dLightDestroy(handle: d3.Light) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const set = h.render3d_instances orelse return .unavailable;
            const status = owner(h, set.lightOwner(handle.unwrap(render.InstanceLightHandle)));
            if (status != .ok) return status;
            set.destroyLight(handle.unwrap(render.InstanceLightHandle)) catch |err| return failure(err);
            return .ok;
        }
        pub fn render3dCameraGet(out: ?*d3.Camera3D) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            dst.* = h.render3d_camera orelse return .unavailable;
            return .ok;
        }
        pub fn worldTransformGet(entity: types.Entity, out: ?*d3.Transform) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const w = h.world orelse return .unavailable;
            const state = w.hierarchy orelse return .unavailable;
            const e = entity.unwrap(scene.Entity);
            if (!w.contains(e)) return .invalid_handle;
            const bytes = w.readComponent(e, state.types.transform) orelse return .not_found;
            dst.* = @bitCast(std.mem.bytesToValue(scene.hierarchy.Transform, bytes));
            return .ok;
        }
        pub fn worldTransformSet(entity: types.Entity, value: ?*const d3.Transform) callconv(.c) Result {
            const supplied = value orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const w = h.world orelse return .unavailable;
            const state = w.hierarchy orelse return .unavailable;
            var t: scene.hierarchy.Transform = @bitCast(supplied.*);
            if (!t.isValid()) return .invalid_argument;
            t.rotation = t.rotation.normalize();
            _ = h.caller() orelse return .refused;
            const e = entity.unwrap(scene.Entity);
            if (!w.contains(e)) return .invalid_handle;
            const bytes = w.getComponent(e, state.types.transform) orelse
                (w.addComponent(e, state.types.transform, std.mem.asBytes(&t)) catch |err| return failure(err));
            @memcpy(bytes, std.mem.asBytes(&t));
            return .ok;
        }
        pub fn worldParentGet(entity: types.Entity, out: ?*types.Entity) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const w = h.world orelse return .unavailable;
            if (!scene.hierarchy.enabled(w)) return .unavailable;
            const e = entity.unwrap(scene.Entity);
            if (!w.contains(e)) return .invalid_handle;
            dst.* = if (scene.hierarchy.parentOf(w, e)) |p| .wrap(p) else .none;
            return .ok;
        }
        pub fn worldParentSet(entity: types.Entity, parent: types.Entity, mode: i32) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const w = h.world orelse return .unavailable;
            if (!scene.hierarchy.enabled(w)) return .unavailable;
            if (mode != 0 and mode != 1) return .invalid_argument;
            _ = h.caller() orelse return .refused;
            const p = if (parent.isNone()) null else parent.unwrap(scene.Entity);
            const result = switch (mode) {
                0 => scene.hierarchy.setParent(w, entity.unwrap(scene.Entity), p),
                1 => scene.hierarchy.setParentKeepWorld(w, entity.unwrap(scene.Entity), p),
                else => return .invalid_argument,
            };
            result catch |err| return failure(err);
            return .ok;
        }
        pub fn worldWorldTransform(entity: types.Entity, out: ?*d3.Mat4) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const w = h.world orelse return .unavailable;
            if (!scene.hierarchy.enabled(w)) return .unavailable;
            const e = entity.unwrap(scene.Entity);
            if (!w.contains(e)) return .invalid_handle;
            dst.* = @bitCast(scene.hierarchy.worldTransform(w, e) orelse return .not_found);
            return .ok;
        }
        pub fn physics3dRaycast(origin: d3.Vec3, direction: d3.Vec3, max_distance: f32, f: ?*const d3.Filter3D, out: ?*d3.RayHit3D, hit: ?*types.Bool) callconv(.c) Result {
            const supplied = f orelse return .invalid_argument;
            const dst = out orelse return .invalid_argument;
            const found = hit orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const w = h.collision3d orelse return .unavailable;
            const selected = filter(supplied.*) orelse return .invalid_argument;
            if (selected.ignore) |body| if (w.body(body) == null) return .invalid_handle;
            const result = w.raycast(vec(origin), vec(direction), max_distance, selected) catch |err| return failure(err);
            dst.* = if (result) |v| hitOut(d3.RayHit3D, v) else std.mem.zeroes(d3.RayHit3D);
            found.* = types.boolOut(result != null);
            return .ok;
        }
        pub fn physics3dShapeCast(s: ?*const d3.Shape3D, p: ?*const d3.Pose3D, displacement: d3.Vec3, f: ?*const d3.Filter3D, out: ?*d3.Hit3D, hit: ?*types.Bool) callconv(.c) Result {
            const supplied_s = s orelse return .invalid_argument;
            const supplied_p = p orelse return .invalid_argument;
            const supplied_f = f orelse return .invalid_argument;
            const dst = out orelse return .invalid_argument;
            const found = hit orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const w = h.collision3d orelse return .unavailable;
            const selected_s = shape(supplied_s.*) orelse return .invalid_argument;
            const selected_p = pose(supplied_p.*) orelse return .invalid_argument;
            const selected_f = filter(supplied_f.*) orelse return .invalid_argument;
            if (selected_f.ignore) |body| if (w.body(body) == null) return .invalid_handle;
            const result = w.shapeCast(selected_s, selected_p, vec(displacement), selected_f) catch |err| return failure(err);
            dst.* = if (result) |v| hitOut(d3.Hit3D, v) else std.mem.zeroes(d3.Hit3D);
            found.* = types.boolOut(result != null);
            return .ok;
        }
        pub fn physics3dOverlap(s: ?*const d3.Shape3D, p: ?*const d3.Pose3D, f: ?*const d3.Filter3D, out: ?[*]d3.Overlap3D, capacity: u32, count: ?*u32, total: ?*u32) callconv(.c) Result {
            const supplied_s = s orelse return .invalid_argument;
            const supplied_p = p orelse return .invalid_argument;
            const supplied_f = f orelse return .invalid_argument;
            const written = count orelse return .invalid_argument;
            const all = total orelse return .invalid_argument;
            if (capacity != 0 and out == null) return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const w = h.collision3d orelse return .unavailable;
            const gpa = h.collision3d_allocator orelse return .unavailable;
            if (capacity > max_hits) return .limit;
            const selected_s = shape(supplied_s.*) orelse return .invalid_argument;
            const selected_p = pose(supplied_p.*) orelse return .invalid_argument;
            const selected_f = filter(supplied_f.*) orelse return .invalid_argument;
            if (selected_f.ignore) |body| if (w.body(body) == null) return .invalid_handle;
            const scratch = gpa.alloc(physics.Overlap, capacity) catch return .out_of_memory;
            defer gpa.free(scratch);
            const result = w.overlap(selected_s, selected_p, selected_f, scratch) catch |err| return failure(err);
            for (scratch[0..result.count], 0..) |v, i| out.?[i] = .{ .body = .wrap(v.body), .user = v.user, .triangle = v.triangle, .reserved = 0 };
            written.* = result.count;
            all.* = result.total;
            return .ok;
        }
        pub fn physics3dBodyCreate(self: types.Mod, desc: ?*const d3.Body3DDesc, out: ?*d3.Body3D) callconv(.c) Result {
            const v = desc orelse return .invalid_argument;
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const w = h.collision3d orelse return .unavailable;
            const gpa = h.collision3d_allocator orelse return .unavailable;
            const s = shape(v.shape) orelse return .invalid_argument;
            const p = pose(v.pose) orelse return .invalid_argument;
            const kind: physics.BodyKind = switch (v.kind) {
                0 => .static,
                1 => .kinematic,
                else => return .invalid_argument,
            };
            const status = creator(h, self);
            if (status != .ok) return status;
            const slot = for (&h.bodies3d) |*entry| {
                if (entry.handle.isNone() or w.body(entry.handle.unwrap(physics.BodyHandle)) == null) break entry;
            } else return .limit;
            const handle = w.addBody(gpa, .{ .shape = s, .pose = p, .kind = kind, .layer = v.layer, .mask = v.mask, .user = v.user }) catch |err| return failure(err);
            slot.* = .{ .handle = .wrap(handle), .owner = self };
            dst.* = slot.handle;
            return .ok;
        }
        pub fn physics3dBodyDestroy(body: d3.Body3D) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const w = h.collision3d orelse return .unavailable;
            const gpa = h.collision3d_allocator orelse return .unavailable;
            const status = bodyOwner(h, body);
            if (status != .ok) return status;
            _ = w.removeBody(gpa, body.unwrap(physics.BodyHandle));
            for (&h.bodies3d) |*entry| if (entry.handle.eql(body)) {
                entry.* = .{};
                break;
            };
            return .ok;
        }
        pub fn physics3dBodySetPose(body: d3.Body3D, value: ?*const d3.Pose3D) callconv(.c) Result {
            const supplied = value orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const w = h.collision3d orelse return .unavailable;
            const gpa = h.collision3d_allocator orelse return .unavailable;
            const p = pose(supplied.*) orelse return .invalid_argument;
            const status = bodyOwner(h, body);
            if (status != .ok) return status;
            _ = w.setPose(gpa, body.unwrap(physics.BodyHandle), p) catch |err| return failure(err);
            return .ok;
        }
        pub fn physics3dBodySetFilter(body: d3.Body3D, layer: u32, mask: u32) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const w = h.collision3d orelse return .unavailable;
            const status = bodyOwner(h, body);
            if (status != .ok) return status;
            _ = w.setFilter(body.unwrap(physics.BodyHandle), layer, mask);
            return .ok;
        }
        pub fn physics3dBodyGet(body: d3.Body3D, out: ?*d3.Body3DDesc) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const w = h.collision3d orelse return .unavailable;
            const b = w.body(body.unwrap(physics.BodyHandle)) orelse return .invalid_handle;
            const s = shapeOut(b.shape) orelse return .unsupported;
            dst.* = .{ .shape = s, .pose = .{ .position = @bitCast(b.pose.position), .rotation = @bitCast(b.pose.rotation) }, .kind = switch (b.kind) {
                .static => 0,
                .kinematic => 1,
            }, .layer = b.layer, .mask = b.mask, .user = b.user };
            return .ok;
        }
        pub fn physics3dCharacterCreate(self: types.Mod, config: ?*const d3.CharacterConfig, feet: d3.Vec3, user: u64, out: ?*d3.Character) callconv(.c) Result {
            const supplied = config orelse return .invalid_argument;
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const w = h.collision3d orelse return .unavailable;
            const gpa = h.collision3d_allocator orelse return .unavailable;
            const c: physics.CharacterConfig = .{ .radius = supplied.radius, .height = supplied.height, .max_slope = supplied.max_slope, .step_height = supplied.step_height, .snap_distance = supplied.snap_distance, .max_move = supplied.max_move, .layer = supplied.layer, .mask = supplied.mask };
            if (!c.valid() or !vec(feet).isFinite()) return .invalid_argument;
            const status = creator(h, self);
            if (status != .ok) return status;
            const slot = for (&h.characters3d) |*entry| {
                if (entry.handle.isNone() or w.character(entry.handle.unwrap(physics.CharacterHandle)) == null) break entry;
            } else return .limit;
            const handle = physics.character.add(w, gpa, c, vec(feet), user) catch |err| return failure(err);
            slot.* = .{ .handle = .wrap(handle), .owner = self };
            dst.* = slot.handle;
            return .ok;
        }
        pub fn physics3dCharacterDestroy(character: d3.Character) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const w = h.collision3d orelse return .unavailable;
            const gpa = h.collision3d_allocator orelse return .unavailable;
            const status = characterOwner(h, character);
            if (status != .ok) return status;
            _ = physics.character.remove(w, gpa, character.unwrap(physics.CharacterHandle));
            for (&h.characters3d) |*entry| if (entry.handle.eql(character)) {
                entry.* = .{};
                break;
            };
            return .ok;
        }
        pub fn physics3dCharacterMove(character: d3.Character, displacement: d3.Vec3, out: ?*d3.CharacterMove) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const w = h.collision3d orelse return .unavailable;
            const gpa = h.collision3d_allocator orelse return .unavailable;
            if (!vec(displacement).isFinite()) return .invalid_argument;
            const status = characterOwner(h, character);
            if (status != .ok) return status;
            const moved = (physics.character.move(w, gpa, character.unwrap(physics.CharacterHandle), vec(displacement), &.{}) catch |err| return failure(err)) orelse return .invalid_handle;
            var result = std.mem.zeroes(d3.CharacterMove);
            result.feet = @bitCast(moved.feet);
            result.ground_triangle = physics.none_triangle;
            if (moved.ground) |ground| {
                result.ground_normal = @bitCast(ground.surface_normal);
                result.ground_body = .wrap(ground.body);
                result.ground_user = ground.user;
                result.ground_triangle = ground.triangle;
            }
            result.walls = moved.walls;
            result.stepped = moved.stepped;
            result.grounded = types.boolOut(moved.grounded);
            result.ceiling = types.boolOut(moved.ceiling);
            result.snapped = types.boolOut(moved.snapped);
            result.depenetrated = types.boolOut(moved.depenetrated);
            result.stuck = types.boolOut(moved.stuck);
            dst.* = result;
            return .ok;
        }
        pub fn physics3dCharacterSetFeet(character: d3.Character, feet: d3.Vec3) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const w = h.collision3d orelse return .unavailable;
            const gpa = h.collision3d_allocator orelse return .unavailable;
            if (!vec(feet).isFinite()) return .invalid_argument;
            const status = characterOwner(h, character);
            if (status != .ok) return status;
            _ = physics.character.setFeet(w, gpa, character.unwrap(physics.CharacterHandle), vec(feet)) catch |err| return failure(err);
            return .ok;
        }
        pub fn physics3dCharacterFeet(character: d3.Character, out: ?*d3.Vec3) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const w = h.collision3d orelse return .unavailable;
            const c = w.character(character.unwrap(physics.CharacterHandle)) orelse return .invalid_handle;
            const b = w.body(c.body) orelse return .invalid_handle;
            dst.* = @bitCast(b.pose.position.sub(.init(0, c.config.height * 0.5, 0)));
            return .ok;
        }
        pub fn physics3dCharacterBody(character: d3.Character, out: ?*d3.Body3D) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const w = h.collision3d orelse return .unavailable;
            const c = w.character(character.unwrap(physics.CharacterHandle)) orelse return .invalid_handle;
            if (w.body(c.body) == null) return .invalid_handle;
            dst.* = .wrap(c.body);
            return .ok;
        }
    };
}
