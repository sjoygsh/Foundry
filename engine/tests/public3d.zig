//! M25 Step 2. Calls through the actual v6 table; no native loader or seeded sweep (Step 3).
const std = @import("std");
const abi = @import("abi");
const core = @import("core");
const scene = @import("scene");
const physics = @import("physics3d");
const render = @import("render3d");
const models = @import("model_content.zig");
const t = std.testing;
const api = abi.TableOf(abi.Host).v6;
const d3 = abi.public3d;
const R = abi.Result;
const V = d3.Vec3;
const zero: V = .{ .x = 0, .y = 0, .z = 0 };
const q: d3.Quat = .{ .x = 0, .y = 0, .z = 0, .w = 1 };
const identity: d3.Mat4 = @bitCast(core.math.Mat4.identity);
const local: d3.Transform = .{ .translation = zero, .rotation = q, .scale = .{ .x = 1, .y = 1, .z = 1 } };
const at: d3.Pose3D = .{ .position = zero, .rotation = q };
const sphere: d3.Shape3D = .{ .kind = 0, .radius = 1, .half_height = 0, .half_extents = zero };
const filter: d3.Filter3D = .{ .mask = ~@as(u32, 0), .reserved = 0, .ignore = .none };
const body_desc: d3.Body3DDesc = .{ .shape = sphere, .pose = at, .kind = 1, .layer = 1, .mask = ~@as(u32, 0), .user = 123 };
const config: d3.CharacterConfig = .{ .radius = 0.3, .height = 1.8, .max_slope = 0.7, .step_height = 0.2, .snap_distance = 0.1, .max_move = 1, .layer = 2, .mask = 1 };
const lamp: d3.Light3D = .{ .kind = 1, .color = .{ .x = 1, .y = 0.8, .z = 0.6 }, .intensity = 10, .range = 4, .inner_cone = 0, .outer_cone = 0.7, .position = zero, .rotation = q, .casts_shadow = 0, .reserved = @splat(0) };

const Fixture = struct {
    stack: *models.Stack,
    world: scene.World,
    collision: physics.World = .{},
    set: render.Instances,
    host: abi.Host = .{},
    a: abi.Mod = .none,
    b: abi.Mod = .none,
    instance: d3.Instance = .none,
    light: d3.Light = .none,
    body: d3.Body3D = .none,
    character: d3.Character = .none,
    fn init() !*Fixture {
        const stack = try models.recordStack();
        errdefer stack.deinit();
        const f = try t.allocator.create(Fixture);
        errdefer t.allocator.destroy(f);
        f.* = .{ .stack = stack, .world = .init(t.allocator, &stack.schemas, .{ .max_hierarchy_depth = 3 }), .set = try .init(t.allocator, .{ .max_instances = 2, .max_lights = 2 }) };
        errdefer f.world.deinit();
        errdefer f.set.deinit(&stack.content);
        _ = try f.world.enableHierarchy();
        f.host.world = &f.world;
        f.host.render3d_content = &stack.content;
        f.host.render3d_instances = &f.set;
        f.host.collision3d = &f.collision;
        f.host.collision3d_allocator = t.allocator;
        f.host.bind();
        f.a = try f.host.issueMod(models.id("a:mod"), "a:mod");
        f.b = try f.host.issueMod(models.id("b:mod"), "b:mod");
        return f;
    }
    fn deinit(f: *Fixture) void {
        f.host.unbind();
        f.collision.deinit(t.allocator);
        f.world.deinit();
        f.set.deinit(&f.stack.content);
        f.stack.deinit();
        t.allocator.destroy(f);
    }
    fn create(f: *Fixture) !void {
        const scope = f.host.enterCaller(f.a);
        defer scope.restore();
        try t.expectEqual(R.ok, api.render3d_instance_create(f.a, models.id("demo:models.pair"), &identity, &f.instance));
        try t.expectEqual(R.ok, api.render3d_light_create(f.a, &lamp, &f.light));
        try t.expectEqual(R.ok, api.physics3d_body_create(f.a, &body_desc, &f.body));
        try t.expectEqual(R.ok, api.physics3d_character_create(f.a, &config, .{ .x = 4, .y = 0, .z = 0 }, 345, &f.character));
    }
};

fn unchanged(comptime T: type, expected: T, actual: T) !void {
    try t.expectEqualSlices(u8, std.mem.asBytes(&expected), std.mem.asBytes(&actual));
}
fn sentinel(comptime T: type) T {
    var result: T = undefined;
    @memset(std.mem.asBytes(&result), 0x5a);
    return result;
}
fn floatOffsets(comptime T: type, comptime base: usize) []const usize {
    if (T == f32) return &.{base};
    var result: []const usize = &.{};
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            for (s.fields) |field| result = result ++ floatOffsets(field.type, base + @offsetOf(T, field.name));
        },
        .array => |a| {
            for (0..a.len) |i| result = result ++ floatOffsets(a.child, base + i * @sizeOf(a.child));
        },
        else => {},
    }
    return result;
}
fn badFloats(comptime T: type, good: T, f: *Fixture, comptime call: anytype) !void {
    const offsets = comptime floatOffsets(T, 0);
    for (offsets) |offset| {
        for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |bad| {
            var value = good;
            @memcpy(std.mem.asBytes(&value)[offset..][0..4], std.mem.asBytes(&bad));
            try t.expectEqual(R.invalid_argument, call(f, &value));
        }
    }
}

fn argument(comptime T: type, f: *Fixture) T {
    if (T == u32) return 1;
    if (T == abi.Mod) return f.a;
    if (T == d3.Instance) return f.instance;
    if (T == d3.Light) return f.light;
    if (T == d3.Body3D) return f.body;
    if (T == d3.Character) return f.character;
    if (T == abi.Entity) return .none;
    if (T == core.ContentId) return models.id("demo:models.pair");
    if (T == V) return .{ .x = 1, .y = 0, .z = 0 };
    if (@typeInfo(T) == .optional) {
        const info = @typeInfo(@typeInfo(T).optional.child).pointer;
        const Storage = struct {
            var one: info.child = undefined;
            var many: [1]info.child = undefined;
        };
        Storage.one = std.mem.zeroes(info.child);
        if (info.child == d3.Mat4) Storage.one = identity;
        if (info.child == d3.Transform) Storage.one = local;
        if (info.child == d3.Pose3D) Storage.one = at;
        if (info.child == d3.Shape3D) Storage.one = sphere;
        if (info.child == d3.Filter3D) Storage.one = filter;
        if (info.child == d3.Light3D) Storage.one = lamp;
        if (info.child == d3.Body3DDesc) Storage.one = body_desc;
        if (info.child == d3.CharacterConfig) Storage.one = config;
        return if (info.size == .many) @as([*]info.child, &Storage.many) else &Storage.one;
    }
    return std.mem.zeroes(T);
}

test "M25 v6 every pointer parameter is checked independently before subsystem lookup" {
    @setEvalBranchQuota(30000);
    const f = try Fixture.init();
    defer f.deinit();
    try f.create();
    const scope = f.host.enterCaller(f.a);
    defer scope.restore();
    const fields = @typeInfo(abi.Api_v6).@"struct".fields[@typeInfo(abi.Api_v5).@"struct".fields.len..];
    inline for (fields) |field| {
        const Fn = @typeInfo(field.type).pointer.child;
        const Args = std.meta.ArgsTuple(Fn);
        inline for (@typeInfo(Args).@"struct".fields) |param| {
            if (comptime @typeInfo(param.type) == .optional) {
                var args: Args = undefined;
                inline for (@typeInfo(Args).@"struct".fields) |p| @field(args, p.name) = argument(p.type, f);
                @field(args, param.name) = null;
                try t.expectEqual(R.invalid_argument, @call(.auto, @field(api, field.name), args));
            }
        }
    }
}

test "M25 v6 caller identity is thread-local and callback registration cannot impersonate" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.create();
    const scope = f.host.enterCaller(f.a);
    defer scope.restore();
    const Thread = struct {
        fn run(ctx: *Fixture, answer: *R) void {
            answer.* = api.physics3d_body_set_filter(ctx.body, 0, 0);
        }
    };
    var result = R.internal;
    var thread = try std.Thread.spawn(.{}, Thread.run, .{ f, &result });
    thread.join();
    try t.expectEqual(R.refused, result);
    const Callback = struct {
        fn update(_: ?*anyopaque, _: ?*const abi.Step) callconv(.c) void {}
    };
    const desc: abi.SystemDesc = .{ .id = models.id("b:system"), .name = .from("b:system"), .ctx = null, .update = Callback.update };
    try t.expectEqual(R.refused, api.world_register_system(f.b, &desc));
    const component: abi.ComponentDesc = .{ .schema = scene.hierarchy.transform_schema.id, .name = .from("b:component"), .size = 40, .alignment = 4, .ctx = null, .construct = null, .destruct = null };
    var component_type: abi.ComponentType = .none;
    try t.expectEqual(R.refused, api.world_register_component(f.b, &component, &component_type));
    try t.expect(component_type.isNone());
}

test "M25 v6 systems and component trampolines identify the callee then restore the caller" {
    const f = try Fixture.init();
    defer f.deinit();
    const scope = f.host.enterCaller(f.a);
    defer scope.restore();
    const Context = struct {
        f: *Fixture,
        seen: u32 = 0,
        fn check(raw: ?*anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(raw.?));
            if (ctx.f.host.caller()) |caller| if (caller.eql(ctx.f.b)) {
                ctx.seen += 1;
            };
        }
        fn update(raw: ?*anyopaque, _: ?*const abi.Step) callconv(.c) void {
            check(raw);
        }
        fn construct(raw: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            check(raw);
        }
        fn destruct(raw: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            check(raw);
        }
    };
    var ctx: Context = .{ .f = f };
    const system = f.host.openSystem(f.b, .{ .ctx = &ctx, .update = Context.update }) orelse return error.TestUnexpectedResult;
    abi.Host.systemUpdate(system, &f.world, .{ .tick = 1, .delta = .fromMillis(16) });
    try t.expect(f.host.caller().?.eql(f.a));
    const component = f.host.openComponent(f.b, .{ .ctx = &ctx, .construct = Context.construct, .destruct = Context.destruct }) orelse return error.TestUnexpectedResult;
    var bytes: [4]u8 = @splat(0);
    abi.Host.componentConstruct(component, &bytes);
    try t.expect(f.host.caller().?.eql(f.a));
    abi.Host.componentDestruct(component, &bytes);
    try t.expect(f.host.caller().?.eql(f.a));
    try t.expectEqual(@as(u32, 3), ctx.seen);
}

test "M25 v6 unscoped hierarchy mutations are refused and unrepresentable reparent is atomic" {
    const f = try Fixture.init();
    defer f.deinit();
    const p: abi.Entity = .wrap(try f.world.create());
    const c: abi.Entity = .wrap(try f.world.create());
    try t.expectEqual(R.refused, api.world_transform_set(p, &local));
    try t.expectEqual(R.refused, api.world_parent_set(p, .none, 0));
    const scope = f.host.enterCaller(f.a);
    defer scope.restore();
    var stretched = local;
    stretched.scale.x = 2;
    var turned = local;
    turned.rotation = @bitCast(core.math.Quat.fromAxisAngle(.init(0, 0, 1), 0.7));
    try t.expectEqual(R.ok, api.world_transform_set(p, &stretched));
    try t.expectEqual(R.ok, api.world_transform_set(c, &turned));
    try t.expectEqual(R.ok, api.world_parent_set(c, p, 0));
    _ = try scene.hierarchy.propagate(&f.world);
    const state = f.world.hierarchy.?;
    const before_transform = try t.allocator.dupe(u8, f.world.readComponent(c.unwrap(scene.Entity), state.types.transform).?);
    defer t.allocator.free(before_transform);
    const before_parent = try t.allocator.dupe(u8, f.world.readComponent(c.unwrap(scene.Entity), state.types.parent).?);
    defer t.allocator.free(before_parent);
    const before_world = try t.allocator.dupe(u8, f.world.readComponent(c.unwrap(scene.Entity), state.types.world_transform).?);
    defer t.allocator.free(before_world);
    try t.expectEqual(R.refused, api.world_parent_set(c, .none, 1));
    try t.expectEqualSlices(u8, before_transform, f.world.readComponent(c.unwrap(scene.Entity), state.types.transform).?);
    try t.expectEqualSlices(u8, before_parent, f.world.readComponent(c.unwrap(scene.Entity), state.types.parent).?);
    try t.expectEqualSlices(u8, before_world, f.world.readComponent(c.unwrap(scene.Entity), state.types.world_transform).?);
}

test "M25 v6 skinned models and hull body reads refuse without changing outputs" {
    const stack = try models.animationStack(1, 1, models.animation_records);
    defer stack.deinit();
    var set = try render.Instances.init(t.allocator, .default);
    defer set.deinit(&stack.content);
    var collision: physics.World = .{};
    defer collision.deinit(t.allocator);
    var host: abi.Host = .{ .render3d_content = &stack.content, .render3d_instances = &set, .collision3d = &collision, .collision3d_allocator = t.allocator };
    host.bind();
    defer host.unbind();
    const self = try host.issueMod(models.id("a:mod"), "a:mod");
    const scope = host.enterCaller(self);
    defer scope.restore();
    var output = sentinel(d3.Instance);
    const prior = output;
    try t.expectEqual(R.unsupported, api.render3d_instance_create(self, models.id("demo:skin.model"), &identity, &output));
    try unchanged(d3.Instance, prior, output);
    const hull = try collision.addHull(t.allocator, &.{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0), .init(0, 0, 1) });
    const body = try collision.addBody(t.allocator, .{ .shape = .{ .hull = hull } });
    var desc = sentinel(d3.Body3DDesc);
    const before = desc;
    try t.expectEqual(R.unsupported, api.physics3d_body_get(.wrap(body), &desc));
    try unchanged(d3.Body3DDesc, before, desc);
}

test "M25 v6 primitive dimensions light ranges and character settings have named refusals" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.create();
    const scope = f.host.enterCaller(f.a);
    defer scope.restore();
    var desc = body_desc;
    var out = sentinel(d3.Body3D);
    desc.shape = .{ .kind = 1, .radius = 0.5, .half_height = 0, .half_extents = zero };
    try t.expectEqual(R.ok, api.physics3d_body_create(f.a, &desc, &out));
    try t.expectEqual(R.ok, api.physics3d_body_destroy(out));
    desc.shape.half_height = -1;
    try t.expectEqual(R.invalid_argument, api.physics3d_body_create(f.a, &desc, &out));
    desc.shape = .{ .kind = 2, .radius = 0, .half_height = 0, .half_extents = .{ .x = 1, .y = 2, .z = 3 } };
    try t.expectEqual(R.ok, api.physics3d_body_create(f.a, &desc, &out));
    try t.expectEqual(R.ok, api.physics3d_body_destroy(out));
    inline for (.{ "x", "y", "z" }) |axis| {
        var bad = desc;
        @field(bad.shape.half_extents, axis) = 0;
        try t.expectEqual(R.invalid_argument, api.physics3d_body_create(f.a, &bad, &out));
        @field(bad.shape.half_extents, axis) = -1;
        try t.expectEqual(R.invalid_argument, api.physics3d_body_create(f.a, &bad, &out));
    }
    desc.shape.radius = 1;
    try t.expectEqual(R.invalid_argument, api.physics3d_body_create(f.a, &desc, &out));
    inline for (.{ "intensity", "range", "inner_cone", "outer_cone" }) |field| {
        var bad = lamp;
        @field(bad, field) = -1;
        try t.expectEqual(R.invalid_argument, api.render3d_light_set(f.light, &bad));
    }
    var bad_light = lamp;
    bad_light.inner_cone = bad_light.outer_cone;
    try t.expectEqual(R.invalid_argument, api.render3d_light_set(f.light, &bad_light));
    bad_light = lamp;
    bad_light.color.x = 2;
    try t.expectEqual(R.invalid_argument, api.render3d_light_set(f.light, &bad_light));
    for ([_]i32{ 0, 2 }) |kind| {
        var valid = lamp;
        valid.kind = kind;
        try t.expectEqual(R.ok, api.render3d_light_set(f.light, &valid));
    }
    inline for (.{ "radius", "height", "max_slope", "step_height", "snap_distance", "max_move" }) |field| {
        var bad = config;
        @field(bad, field) = -1;
        var c = sentinel(d3.Character);
        const prior = c;
        try t.expectEqual(R.invalid_argument, api.physics3d_character_create(f.a, &bad, zero, 0, &c));
        try unchanged(d3.Character, prior, c);
    }
}

test "M25 v6 tolerated rotations are normalized before they are stored or turned into light poses" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.create();
    const scope = f.host.enterCaller(f.a);
    defer scope.restore();
    const rotation = core.math.Quat.fromAxisAngle(.init(0, 0, 1), 0.7);
    const supplied: core.math.Quat = .{ .x = rotation.x * 1.0003, .y = rotation.y * 1.0003, .z = rotation.z * 1.0003, .w = rotation.w * 1.0003 };
    const normalized = supplied.normalize();
    var transform = local;
    transform.rotation = @bitCast(supplied);
    const entity: abi.Entity = .wrap(try f.world.create());
    try t.expectEqual(R.ok, api.world_transform_set(entity, &transform));
    var got: d3.Transform = undefined;
    try t.expectEqual(R.ok, api.world_transform_get(entity, &got));
    try unchanged(d3.Quat, @bitCast(normalized), got.rotation);
    var value = lamp;
    value.rotation = @bitCast(supplied);
    try t.expectEqual(R.ok, api.render3d_light_set(f.light, &value));
    const actual = f.set.lights.get(f.light.unwrap(render.InstanceLightHandle)).?.light.world;
    try unchanged(core.math.Mat4, (core.math.Transform{ .rotation = normalized }).toMat4(), actual);
}

test "M25 v6 retained instance calls enforce scope, owners, stale generations and content schemas" {
    const f = try Fixture.init();
    defer f.deinit();
    var out = sentinel(d3.Instance);
    const before = out;
    try t.expectEqual(R.refused, api.render3d_instance_create(f.a, models.id("demo:models.pair"), &identity, &out));
    try unchanged(d3.Instance, before, out);
    try f.create();
    {
        const scope = f.host.enterCaller(f.b);
        defer scope.restore();
        try t.expectEqual(R.refused, api.render3d_instance_create(f.a, models.id("demo:models.pair"), &identity, &out));
        try t.expectEqual(R.refused, api.render3d_instance_destroy(f.instance));
        try t.expectEqual(R.refused, api.render3d_instance_set_world(f.instance, &identity));
        try t.expectEqual(R.refused, api.render3d_instance_set_material(f.instance, 0, .none));
        try t.expectEqual(R.refused, api.render3d_instance_set_visible(f.instance, 0));
    }
    const scope = f.host.enterCaller(f.a);
    defer scope.restore();
    try t.expectEqual(R.invalid_handle, api.render3d_instance_create(.none, models.id("demo:models.pair"), &identity, &out));
    try t.expectEqual(R.invalid_argument, api.render3d_instance_create(f.a, models.id("demo:materials.red"), &identity, &out));
    try t.expectEqual(R.not_found, api.render3d_instance_create(f.a, models.id("demo:missing"), &identity, &out));
    try t.expectEqual(R.ok, api.render3d_instance_create(f.a, models.id("demo:models.pair"), &identity, &out));
    var no_room = before;
    try t.expectEqual(R.limit, api.render3d_instance_create(f.a, models.id("demo:models.pair"), &identity, &no_room));
    try unchanged(d3.Instance, before, no_room);
    try t.expectEqual(R.invalid_argument, api.render3d_instance_set_material(f.instance, 20, models.id("demo:materials.red")));
    try t.expectEqual(R.invalid_argument, api.render3d_instance_set_material(f.instance, 0, models.id("demo:models.pair")));
    try t.expectEqual(R.ok, api.render3d_instance_set_material(f.instance, 0, models.id("demo:materials.red")));
    try t.expectEqual(R.ok, api.render3d_instance_set_material(f.instance, 0, .none));
    var projective = identity;
    projective.elements[3] = 1;
    try t.expectEqual(R.invalid_argument, api.render3d_instance_set_world(f.instance, &projective));
    try t.expectEqual(R.ok, api.render3d_instance_set_world(f.instance, &identity));
    try t.expectEqual(R.ok, api.render3d_instance_set_visible(f.instance, 2));
    const stale = f.instance;
    try t.expectEqual(R.ok, api.render3d_instance_destroy(stale));
    try t.expectEqual(R.ok, api.render3d_instance_create(f.a, models.id("demo:models.pair"), &identity, &f.instance));
    try t.expectEqual(R.invalid_handle, api.render3d_instance_destroy(stale));
    try t.expectEqual(R.invalid_handle, api.render3d_instance_set_visible(stale, 0));
    try t.expectEqual(R.invalid_handle, api.render3d_instance_set_world(stale, &identity));
    try t.expectEqual(R.invalid_handle, api.render3d_instance_set_material(stale, 0, .none));
}

test "M25 v6 light calls and camera snapshot never expose a frame callback or camera write" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.create();
    var camera = sentinel(d3.Camera3D);
    const original = camera;
    try t.expectEqual(R.unavailable, api.render3d_camera_get(&camera));
    try unchanged(d3.Camera3D, original, camera);
    f.host.render3d_camera = .{ .position = zero, .rotation = q, .fov_y = 1, .near = 0.1, .far = 100, .width = 32, .height = 32 };
    try t.expectEqual(R.ok, api.render3d_camera_get(&camera));
    try t.expectEqual(@as(u32, 32), camera.width);
    try t.expectEqual(R.invalid_argument, api.render3d_camera_get(null));
    try t.expectEqual(R.refused, api.render3d_light_set(f.light, &lamp));
    try t.expectEqual(R.refused, api.render3d_light_destroy(f.light));
    {
        const scope = f.host.enterCaller(f.b);
        defer scope.restore();
        try t.expectEqual(R.refused, api.render3d_light_set(f.light, &lamp));
        try t.expectEqual(R.refused, api.render3d_light_destroy(f.light));
    }
    const scope = f.host.enterCaller(f.a);
    defer scope.restore();
    var out = sentinel(d3.Light);
    try t.expectEqual(R.ok, api.render3d_light_create(f.a, &lamp, &out));
    var no_room = sentinel(d3.Light);
    const before = no_room;
    try t.expectEqual(R.limit, api.render3d_light_create(f.a, &lamp, &no_room));
    try unchanged(d3.Light, before, no_room);
    for ([_]i32{ -1, 3, 100 }) |kind| {
        var bad = lamp;
        bad.kind = kind;
        try t.expectEqual(R.invalid_argument, api.render3d_light_set(f.light, &bad));
    }
    var shadow = lamp;
    shadow.casts_shadow = 1;
    try t.expectEqual(R.invalid_argument, api.render3d_light_set(f.light, &shadow));
    var nonunit = lamp;
    nonunit.rotation.w = 2;
    try t.expectEqual(R.invalid_argument, api.render3d_light_set(f.light, &nonunit));
    var reserved = lamp;
    reserved.reserved[1] = 1;
    try t.expectEqual(R.invalid_argument, api.render3d_light_set(f.light, &reserved));
    try t.expectEqual(R.ok, api.render3d_light_set(f.light, &lamp));
    const stale = f.light;
    try t.expectEqual(R.ok, api.render3d_light_destroy(stale));
    try t.expectEqual(R.ok, api.render3d_light_create(f.a, &lamp, &f.light));
    try t.expectEqual(R.invalid_handle, api.render3d_light_set(stale, &lamp));
    try t.expectEqual(R.invalid_handle, api.render3d_light_destroy(stale));
}

test "M25 v6 transforms and reparent refusals preserve every hierarchy component" {
    const f = try Fixture.init();
    defer f.deinit();
    const scope = f.host.enterCaller(f.a);
    defer scope.restore();
    var entities: [5]abi.Entity = undefined;
    for (&entities) |*e| {
        e.* = .wrap(try f.world.create());
        try t.expectEqual(R.ok, api.world_transform_set(e.*, &local));
    }
    for (1..4) |i| try t.expectEqual(R.ok, api.world_parent_set(entities[i], entities[i - 1], 0));
    _ = try scene.hierarchy.propagate(&f.world);
    var before: [5]d3.Mat4 = undefined;
    for (entities, &before) |e, *m| try t.expectEqual(R.ok, api.world_world_transform(e, m));
    try t.expectEqual(R.refused, api.world_parent_set(entities[0], entities[3], 0));
    try t.expectEqual(R.limit, api.world_parent_set(entities[4], entities[3], 0));
    try t.expectEqual(R.invalid_argument, api.world_parent_set(entities[1], entities[0], 3));
    var singular = local;
    singular.scale.x = 0;
    try t.expectEqual(R.ok, api.world_transform_set(entities[4], &singular));
    try t.expectEqual(R.refused, api.world_parent_set(entities[1], entities[4], 1));
    for (entities, before) |e, m| {
        var actual: d3.Mat4 = undefined;
        try t.expectEqual(R.ok, api.world_world_transform(e, &actual));
        try unchanged(d3.Mat4, m, actual);
    }
    var parent: abi.Entity = .none;
    try t.expectEqual(R.ok, api.world_parent_get(entities[1], &parent));
    try t.expect(parent.eql(entities[0]));
    try t.expectEqual(R.ok, api.world_parent_set(entities[1], .none, 1));
    try t.expectEqual(R.ok, api.world_parent_get(entities[1], &parent));
    try t.expect(parent.isNone());
    var got = sentinel(d3.Transform);
    try t.expectEqual(R.ok, api.world_transform_get(entities[0], &got));
    try unchanged(d3.Transform, local, got);
    const dead: abi.Entity = .wrap(try f.world.create());
    _ = f.world.destroy(dead.unwrap(scene.Entity));
    const original = got;
    try t.expectEqual(R.invalid_handle, api.world_transform_get(dead, &got));
    try unchanged(d3.Transform, original, got);
    try t.expectEqual(R.invalid_handle, api.world_transform_set(dead, &local));
    try t.expectEqual(R.invalid_handle, api.world_parent_get(dead, &parent));
    try t.expectEqual(R.invalid_handle, api.world_parent_set(dead, .none, 0));
    try t.expectEqual(R.invalid_handle, api.world_world_transform(dead, &before[0]));
    const bare: abi.Entity = .wrap(try f.world.create());
    try t.expectEqual(R.not_found, api.world_transform_get(bare, &got));
    try t.expectEqual(R.not_found, api.world_world_transform(bare, &before[0]));
    try t.expectEqual(R.ok, api.world_transform_set(bare, &local));
    var invalid = local;
    invalid.rotation.w = 2;
    try t.expectEqual(R.invalid_argument, api.world_transform_set(bare, &invalid));
}

test "M25 v6 bodies preserve ownership, stale handles and caller outputs" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.create();
    var got = sentinel(d3.Body3DDesc);
    try t.expectEqual(R.ok, api.physics3d_body_get(f.body, &got));
    try unchanged(d3.Body3DDesc, body_desc, got);
    const host_body: d3.Body3D = .wrap(try f.collision.addBody(t.allocator, .{ .shape = .{ .sphere = .{ .radius = 1 } } }));
    for ([_]d3.Body3D{ host_body, f.body }) |body| {
        const scope = f.host.enterCaller(f.b);
        defer scope.restore();
        try t.expectEqual(R.refused, api.physics3d_body_destroy(body));
        try t.expectEqual(R.refused, api.physics3d_body_set_pose(body, &at));
        try t.expectEqual(R.refused, api.physics3d_body_set_filter(body, 0, 0));
        try t.expectEqual(R.ok, api.physics3d_body_get(body, &got));
    }
    const scope = f.host.enterCaller(f.a);
    defer scope.restore();
    var output = sentinel(d3.Body3D);
    const before = output;
    try t.expectEqual(R.invalid_handle, api.physics3d_body_create(.none, &body_desc, &output));
    try unchanged(d3.Body3D, before, output);
    var bad = body_desc;
    bad.kind = 2;
    try t.expectEqual(R.invalid_argument, api.physics3d_body_create(f.a, &bad, &output));
    try unchanged(d3.Body3D, before, output);
    bad = body_desc;
    bad.pose.rotation.w = 2;
    try t.expectEqual(R.invalid_argument, api.physics3d_body_create(f.a, &bad, &output));
    for ([_]i32{ -1, 3 }) |kind| {
        bad = body_desc;
        bad.shape.kind = kind;
        try t.expectEqual(R.invalid_argument, api.physics3d_body_create(f.a, &bad, &output));
    }
    bad = body_desc;
    bad.shape.radius = 0;
    try t.expectEqual(R.invalid_argument, api.physics3d_body_create(f.a, &bad, &output));
    bad.shape.radius = -1;
    try t.expectEqual(R.invalid_argument, api.physics3d_body_create(f.a, &bad, &output));
    var moved = at;
    moved.position.x = 2;
    try t.expectEqual(R.ok, api.physics3d_body_set_pose(f.body, &moved));
    try t.expectEqual(R.ok, api.physics3d_body_set_filter(f.body, 4, 5));
    try t.expectEqual(R.ok, api.physics3d_body_get(f.body, &got));
    try t.expectEqual(@as(u32, 4), got.layer);
    try t.expectEqual(@as(f32, 2), got.pose.position.x);
    const stale = f.body;
    try t.expectEqual(R.ok, api.physics3d_body_destroy(stale));
    try t.expectEqual(R.ok, api.physics3d_body_create(f.a, &body_desc, &f.body));
    try t.expectEqual(R.invalid_handle, api.physics3d_body_destroy(stale));
    try t.expectEqual(R.invalid_handle, api.physics3d_body_set_pose(stale, &at));
    try t.expectEqual(R.invalid_handle, api.physics3d_body_set_filter(stale, 1, 1));
    got = sentinel(d3.Body3DDesc);
    const old = got;
    try t.expectEqual(R.invalid_handle, api.physics3d_body_get(stale, &got));
    try unchanged(d3.Body3DDesc, old, got);
}

test "M25 v6 characters cannot be attacked through their backing bodies" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.create();
    var feet = sentinel(V);
    var backing: d3.Body3D = .none;
    var movement = sentinel(d3.CharacterMove);
    try t.expectEqual(R.ok, api.physics3d_character_feet(f.character, &feet));
    try t.expectEqual(@as(f32, 4), feet.x);
    try t.expectEqual(R.ok, api.physics3d_character_body(f.character, &backing));
    {
        const scope = f.host.enterCaller(f.b);
        defer scope.restore();
        try t.expectEqual(R.refused, api.physics3d_character_destroy(f.character));
        try t.expectEqual(R.refused, api.physics3d_character_move(f.character, zero, &movement));
        try t.expectEqual(R.refused, api.physics3d_character_set_feet(f.character, zero));
    }
    const scope = f.host.enterCaller(f.a);
    defer scope.restore();
    try t.expectEqual(R.refused, api.physics3d_body_destroy(backing));
    try t.expectEqual(R.refused, api.physics3d_body_set_pose(backing, &at));
    try t.expectEqual(R.refused, api.physics3d_body_set_filter(backing, 0, 0));
    const old = movement;
    try t.expectEqual(R.invalid_argument, api.physics3d_character_move(f.character, .{ .x = 100, .y = 0, .z = 0 }, &movement));
    try unchanged(d3.CharacterMove, old, movement);
    try t.expectEqual(R.ok, api.physics3d_character_move(f.character, .{ .x = 0.2, .y = 0, .z = 0 }, &movement));
    try t.expectApproxEqAbs(@as(f32, 4.2), movement.feet.x, 0.001);
    try t.expectEqual(R.ok, api.physics3d_character_set_feet(f.character, .{ .x = 3, .y = 0, .z = 0 }));
    var bad = config;
    bad.radius = 0;
    var output = sentinel(d3.Character);
    const original = output;
    try t.expectEqual(R.invalid_argument, api.physics3d_character_create(f.a, &bad, zero, 0, &output));
    try unchanged(d3.Character, original, output);
    bad = config;
    bad.height = 0.1;
    try t.expectEqual(R.invalid_argument, api.physics3d_character_create(f.a, &bad, zero, 0, &output));
    const stale = f.character;
    try t.expectEqual(R.ok, api.physics3d_character_destroy(stale));
    try t.expectEqual(R.ok, api.physics3d_character_create(f.a, &config, zero, 0, &f.character));
    try t.expectEqual(R.invalid_handle, api.physics3d_character_destroy(stale));
    try t.expectEqual(R.invalid_handle, api.physics3d_character_move(stale, zero, &movement));
    try t.expectEqual(R.invalid_handle, api.physics3d_character_set_feet(stale, zero));
    try t.expectEqual(R.invalid_handle, api.physics3d_character_feet(stale, &feet));
    try t.expectEqual(R.invalid_handle, api.physics3d_character_body(stale, &backing));
}

test "M25 v6 queries report hits, misses, filters and bounded truncation without ownership" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.create();
    var ray = sentinel(d3.RayHit3D);
    var hit: abi.Bool = 9;
    try t.expectEqual(R.ok, api.physics3d_raycast(.{ .x = 0, .y = 3, .z = 0 }, .{ .x = 0, .y = -1, .z = 0 }, 5, &filter, &ray, &hit));
    try t.expectEqual(@as(abi.Bool, 1), hit);
    try t.expect(ray.body.eql(f.body));
    try t.expectEqual(R.ok, api.physics3d_raycast(.{ .x = 10, .y = 3, .z = 0 }, .{ .x = 0, .y = -1, .z = 0 }, 5, &filter, &ray, &hit));
    try t.expectEqual(@as(abi.Bool, 0), hit);
    try unchanged(d3.RayHit3D, std.mem.zeroes(d3.RayHit3D), ray);
    ray = sentinel(d3.RayHit3D);
    const old = ray;
    hit = 9;
    try t.expectEqual(R.invalid_argument, api.physics3d_raycast(zero, zero, 1, &filter, &ray, &hit));
    try unchanged(d3.RayHit3D, old, ray);
    try t.expectEqual(@as(abi.Bool, 9), hit);
    try t.expectEqual(R.invalid_argument, api.physics3d_raycast(zero, .{ .x = 1, .y = 0, .z = 0 }, -1, &filter, &ray, &hit));
    var cast = sentinel(d3.Hit3D);
    var start = at;
    start.position.y = 4;
    try t.expectEqual(R.ok, api.physics3d_shape_cast(&sphere, &start, .{ .x = 0, .y = -5, .z = 0 }, &filter, &cast, &hit));
    try t.expectEqual(@as(abi.Bool, 1), hit);
    try t.expect(cast.body.eql(f.body));
    var count: u32 = 99;
    var total: u32 = 99;
    try t.expectEqual(R.ok, api.physics3d_overlap(&sphere, &at, &filter, null, 0, &count, &total));
    try t.expectEqual(@as(u32, 0), count);
    try t.expectEqual(@as(u32, 1), total);
    var overlaps: [1]d3.Overlap3D = undefined;
    try t.expectEqual(R.ok, api.physics3d_overlap(&sphere, &at, &filter, &overlaps, 1, &count, &total));
    try t.expect(overlaps[0].body.eql(f.body));
    const prior = overlaps[0];
    count = 99;
    total = 99;
    try t.expectEqual(R.limit, api.physics3d_overlap(&sphere, &at, &filter, &overlaps, 4097, &count, &total));
    try unchanged(d3.Overlap3D, prior, overlaps[0]);
    try t.expectEqual(@as(u32, 99), count);
    try t.expectEqual(@as(u32, 99), total);
    try t.expectEqual(R.invalid_argument, api.physics3d_overlap(&sphere, &at, &filter, null, 1, &count, &total));
    var excluded = filter;
    excluded.ignore = f.body;
    try t.expectEqual(R.ok, api.physics3d_overlap(&sphere, &at, &excluded, &overlaps, 1, &count, &total));
    try t.expectEqual(@as(u32, 0), total);
    excluded.reserved = 1;
    try t.expectEqual(R.invalid_argument, api.physics3d_overlap(&sphere, &at, &excluded, &overlaps, 1, &count, &total));
    excluded = filter;
    excluded.ignore = .{ .bits = 123 };
    try t.expectEqual(R.invalid_handle, api.physics3d_overlap(&sphere, &at, &excluded, &overlaps, 1, &count, &total));
    try t.expectEqual(R.invalid_handle, api.physics3d_shape_cast(&sphere, &at, zero, &excluded, &cast, &hit));
    try t.expectEqual(R.invalid_handle, api.physics3d_raycast(zero, .{ .x = 1, .y = 0, .z = 0 }, 1, &excluded, &ray, &hit));
}

test "M25 v6 fixed ownership tables refuse capacity and recycle only stale entries" {
    const f = try Fixture.init();
    defer f.deinit();
    const scope = f.host.enterCaller(f.a);
    defer scope.restore();
    var body: d3.Body3D = .none;
    for (0..256) |_| try t.expectEqual(R.ok, api.physics3d_body_create(f.a, &body_desc, &body));
    var refused = sentinel(d3.Body3D);
    const before = refused;
    try t.expectEqual(R.limit, api.physics3d_body_create(f.a, &body_desc, &refused));
    try unchanged(d3.Body3D, before, refused);
    try t.expectEqual(R.ok, api.physics3d_body_destroy(body));
    try t.expectEqual(R.ok, api.physics3d_body_create(f.a, &body_desc, &body));
    var c: d3.Character = .none;
    for (0..16) |_| try t.expectEqual(R.ok, api.physics3d_character_create(f.a, &config, .{ .x = 10, .y = 0, .z = 0 }, 0, &c));
    var no_room = sentinel(d3.Character);
    const old = no_room;
    try t.expectEqual(R.limit, api.physics3d_character_create(f.a, &config, zero, 0, &no_room));
    try unchanged(d3.Character, old, no_room);
    try t.expectEqual(R.ok, api.physics3d_character_destroy(c));
    try t.expectEqual(R.ok, api.physics3d_character_create(f.a, &config, zero, 0, &c));
}

test "M25 v6 every floating input refuses NaN and both infinities" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.create();
    const scope = f.host.enterCaller(f.a);
    defer scope.restore();
    const Calls = struct {
        fn mat(ctx: *Fixture, v: *const d3.Mat4) R {
            return api.render3d_instance_set_world(ctx.instance, v);
        }
        fn light(ctx: *Fixture, v: *const d3.Light3D) R {
            return api.render3d_light_set(ctx.light, v);
        }
        fn body(ctx: *Fixture, v: *const d3.Body3DDesc) R {
            var out = sentinel(d3.Body3D);
            return api.physics3d_body_create(ctx.a, v, &out);
        }
        fn pose(ctx: *Fixture, v: *const d3.Pose3D) R {
            return api.physics3d_body_set_pose(ctx.body, v);
        }
        fn conf(ctx: *Fixture, v: *const d3.CharacterConfig) R {
            var out = sentinel(d3.Character);
            return api.physics3d_character_create(ctx.a, v, zero, 0, &out);
        }
        fn feet(ctx: *Fixture, v: *const V) R {
            return api.physics3d_character_set_feet(ctx.character, v.*);
        }
        fn move(ctx: *Fixture, v: *const V) R {
            var out = sentinel(d3.CharacterMove);
            return api.physics3d_character_move(ctx.character, v.*, &out);
        }
        fn transform(ctx: *Fixture, v: *const d3.Transform) R {
            var it = ctx.world.entities.iterator();
            return api.world_transform_set(.wrap(it.next().?.id), v);
        }
        fn shapeQuery(_: *Fixture, v: *const d3.Shape3D) R {
            var count: u32 = 0;
            var total: u32 = 0;
            return api.physics3d_overlap(v, &at, &filter, null, 0, &count, &total);
        }
        fn poseQuery(_: *Fixture, v: *const d3.Pose3D) R {
            var out = sentinel(d3.Hit3D);
            var hit: abi.Bool = 9;
            return api.physics3d_shape_cast(&sphere, v, zero, &filter, &out, &hit);
        }
        fn rayOrigin(_: *Fixture, v: *const V) R {
            var out = sentinel(d3.RayHit3D);
            var hit: abi.Bool = 9;
            return api.physics3d_raycast(v.*, .{ .x = 1, .y = 0, .z = 0 }, 1, &filter, &out, &hit);
        }
        fn rayDirection(_: *Fixture, v: *const V) R {
            var out = sentinel(d3.RayHit3D);
            var hit: abi.Bool = 9;
            return api.physics3d_raycast(zero, v.*, 1, &filter, &out, &hit);
        }
        fn castDisplacement(_: *Fixture, v: *const V) R {
            var out = sentinel(d3.Hit3D);
            var hit: abi.Bool = 9;
            return api.physics3d_shape_cast(&sphere, &at, v.*, &filter, &out, &hit);
        }
    };
    const e = try f.world.create();
    _ = e;
    try badFloats(d3.Mat4, identity, f, Calls.mat);
    try badFloats(d3.Light3D, lamp, f, Calls.light);
    try badFloats(d3.Body3DDesc, body_desc, f, Calls.body);
    try badFloats(d3.Pose3D, at, f, Calls.pose);
    try badFloats(d3.CharacterConfig, config, f, Calls.conf);
    try badFloats(V, zero, f, Calls.feet);
    try badFloats(V, zero, f, Calls.move);
    try badFloats(d3.Transform, local, f, Calls.transform);
    try badFloats(d3.Shape3D, sphere, f, Calls.shapeQuery);
    try badFloats(d3.Pose3D, at, f, Calls.poseQuery);
    try badFloats(V, zero, f, Calls.rayOrigin);
    try badFloats(V, .{ .x = 1, .y = 0, .z = 0 }, f, Calls.rayDirection);
    try badFloats(V, zero, f, Calls.castDisplacement);
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |bad| {
        var ray = sentinel(d3.RayHit3D);
        var found: abi.Bool = 7;
        try t.expectEqual(R.invalid_argument, api.physics3d_raycast(zero, .{ .x = 1, .y = 0, .z = 0 }, bad, &filter, &ray, &found));
    }
}

test "M25 v6 nested caller scopes restore authority and refusal releases only its owner" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.create();
    try t.expect(f.host.caller() == null);
    const a = f.host.enterCaller(f.a);
    try t.expect(f.host.caller().?.eql(f.a));
    const b = f.host.enterCaller(f.b);
    try t.expect(f.host.caller().?.eql(f.b));
    var foreign: d3.Body3D = .none;
    try t.expectEqual(R.ok, api.physics3d_body_create(f.b, &body_desc, &foreign));
    b.restore();
    try t.expect(f.host.caller().?.eql(f.a));
    f.host.refuseMod(f.a);
    try t.expect(f.host.caller() == null);
    try t.expect(f.set.instanceOwner(f.instance.unwrap(render.InstanceHandle)) == null);
    try t.expect(f.set.lightOwner(f.light.unwrap(render.InstanceLightHandle)) == null);
    try t.expect(f.collision.body(f.body.unwrap(physics.BodyHandle)) == null);
    try t.expect(f.collision.character(f.character.unwrap(physics.CharacterHandle)) == null);
    try t.expect(f.collision.body(foreign.unwrap(physics.BodyHandle)) != null);
    a.restore();
    try t.expect(f.host.caller() == null);
}
