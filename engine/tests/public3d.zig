//! M25 Steps 2–3: per-call refusals, real native consumers and seeded hostile sweeps.
const std = @import("std");
const abi = @import("abi");
const core = @import("core");
const scene = @import("scene");
const physics = @import("physics3d");
const render = @import("render3d");
const models = @import("model_content.zig");
const platform = @import("platform");
const mod = @import("mod");
const options = @import("mod_pipeline_options");
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

fn testCamera() d3.Camera3D {
    return .{ .position = zero, .rotation = q, .fov_y = 1, .near = 0.1, .far = 100, .width = 32, .height = 32 };
}

fn stageLibrary(f: *Fixture, source: []const u8, native: []const u8) ![]u8 {
    const name = try abi.libraryFileNameAlloc(t.allocator, native);
    defer t.allocator.free(name);
    const path = try platform.os.joinPath(t.allocator, &.{ f.stack.out, "native", name });
    errdefer t.allocator.free(path);
    const bytes = try f.stack.os.readFile(t.allocator, source, 64 << 20);
    defer t.allocator.free(bytes);
    const relative = try std.fmt.allocPrint(t.allocator, "native/{s}", .{name});
    defer t.allocator.free(relative);
    try f.stack.writeUnder(f.stack.out, relative, bytes);
    return path;
}

fn loadNative(f: *Fixture, loader: *abi.NativeLoaderOf(abi.Host), native: []const u8) !void {
    const entries = [_]mod.Entry{.{ .id = models.id("native:test"), .name = "native:test", .base_dir = f.stack.out, .file = "", .root = "native", .version = 1, .abi = .{ .min = 6, .max = 6 }, .native = native }};
    try loader.load(&entries, &f.stack.diags);
    try t.expectEqual(@as(usize, 1), loader.loaded.items.len);
    const loaded = &loader.loaded.items[0];
    const Probe = *const fn () callconv(.c) u32;
    const failed = loaded.library.symbol(Probe, "foundry_test_failure") orelse return error.MissingProbe;
    try t.expectEqual(@as(u32, 0), failed());
}

fn drawProtected(f: *Fixture) !u64 {
    var hash = std.hash.Wyhash.init(0);
    try f.stack.begin();
    try f.set.submit(&f.stack.content, &f.stack.renderer);
    try t.expectEqual(@as(usize, 2), f.stack.renderer.draws.items.len);
    for (f.stack.renderer.draws.items) |draw| {
        hash.update(std.mem.asBytes(&draw.world));
        const material = draw.material.bits();
        hash.update(std.mem.asBytes(&material));
    }
    try t.expectEqual(@as(u32, 1), f.stack.renderer.light_count);
    const light = f.stack.renderer.lights[0];
    hash.update(std.mem.asBytes(&light.world));
    hash.update(std.mem.asBytes(&light.color));
    hash.update(std.mem.asBytes(&light.intensity));
    hash.update(std.mem.asBytes(&light.range));
    try f.stack.finish(null);
    try t.expectEqual(@as(usize, 0), f.stack.violations());
    return hash.final();
}

/// Same-binary character tour before/after the adversary; reset feet between runs.
/// This is the integration host's tour, not Step 5's not-yet-hosted sandbox mod tour.
fn playerReplay(f: *Fixture) !u64 {
    const handle = f.character.unwrap(physics.CharacterHandle);
    _ = try physics.character.setFeet(&f.collision, t.allocator, handle, .init(4, 0, 0));
    var hash = std.hash.Wyhash.init(0);
    for (0..120) |tick| {
        const dx: f32 = if (tick < 60) 0.025 else -0.025;
        const moved = (try physics.character.move(&f.collision, t.allocator, handle, .init(dx, -0.01, 0), &.{})).?;
        hash.update(std.mem.asBytes(&moved.feet));
        hash.update(&.{ @intFromBool(moved.grounded), @intFromBool(moved.stuck) });
        hash.update(std.mem.asBytes(&moved.walls));
    }
    _ = try physics.character.setFeet(&f.collision, t.allocator, handle, .init(4, 0, 0));
    return hash.final();
}

fn hierarchySnapshot(f: *Fixture) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(t.allocator);
    const types = f.world.hierarchy.?.types;
    var entities = f.world.liveEntities();
    while (entities.next()) |entity| {
        const bits = entity.bits();
        try bytes.appendSlice(t.allocator, std.mem.asBytes(&bits));
        for ([_]scene.ComponentType{ types.transform, types.parent, types.world_transform }) |kind| {
            const value = f.world.readComponent(entity, kind);
            try bytes.append(t.allocator, @intFromBool(value != null));
            if (value) |payload| try bytes.appendSlice(t.allocator, payload);
        }
    }
    return bytes.toOwnedSlice(t.allocator);
}

test "M25 v6 C99 conformance client runs all 28 entries through the real native loader" {
    const f = try Fixture.init();
    defer f.deinit();
    f.host.render3d_camera = testCamera();
    const path = try stageLibrary(f, options.render3d_client_path, "render3d_client");
    defer t.allocator.free(path);
    // The registry caches unused assets; warm the same model/material before comparing.
    const warm_model = try f.stack.content.acquireModel(models.id("demo:models.pair"));
    f.stack.content.releaseModel(warm_model);
    const warm_material = try f.stack.content.acquireMaterial(models.id("demo:materials.crate"));
    f.stack.content.releaseMaterial(warm_material);
    const held = .{ f.stack.content.models.count(), f.stack.content.materials.count(), f.stack.assets.count() };
    var loader = abi.NativeLoaderOf(abi.Host).init(t.allocator, &f.host);
    defer loader.deinit();
    try loadNative(f, &loader, "render3d_client");
    try t.expect(f.host.modId(loader.loaded.items[0].self) != null);
    try t.expectEqual(@as(usize, 0), f.stack.diags.count());
    const Probe = *const fn () callconv(.c) u32;
    try t.expectEqual(@as(u32, 28), loader.loaded.items[0].library.symbol(Probe, "foundry_test_calls").?());
    _ = try scene.hierarchy.propagate(&f.world);
    f.world.update(.{ .tick = 1, .delta = .fromNanos(16_666_667) });
    try t.expectEqual(@as(u32, 0), loader.loaded.items[0].library.symbol(Probe, "foundry_test_failure").?());
    try t.expectEqual(@as(u32, 29), loader.loaded.items[0].library.symbol(Probe, "foundry_test_calls").?());
    try t.expectEqual(held, .{ f.stack.content.models.count(), f.stack.content.materials.count(), f.stack.assets.count() });
    try t.expectEqual(@as(u32, 0), f.world.entityCount());
    for (f.host.bodies3d) |entry| try t.expect(entry.handle.isNone());
    for (f.host.characters3d) |entry| try t.expect(entry.handle.isNone());
    try t.expect(f.host.caller() == null);
}

const v6_fields = @typeInfo(abi.Api_v6).@"struct".fields[@typeInfo(abi.Api_v5).@"struct".fields.len..];
const Rng = core.rng.Pcg32;

fn randomFloat(rng: *Rng) f32 {
    // Full bit patterns plus deliberately frequent special/boundary values.
    return @bitCast(switch (rng.below(8)) {
        0 => @as(u32, 0x7fc00001),
        1 => @as(u32, 0x7f800000),
        2 => @as(u32, 0xff800000),
        3 => @as(u32, 1), // positive denormal
        4 => @as(u32, 0x80000001), // negative denormal
        5 => @as(u32, 0x7f7fffff),
        else => rng.next(),
    });
}

fn sweepValue(comptime T: type, rng: *Rng, f: *Fixture, entity: abi.Entity) T {
    if (T == f32) return if (rng.boolean()) randomFloat(rng) else 10;
    if (T == u8) return @truncate(rng.next());
    if (T == u32) return switch (rng.below(6)) {
        0 => 0,
        1 => 1,
        2 => 4096,
        3 => 4097,
        else => rng.next(),
    };
    if (T == i32) return if (rng.boolean()) @intCast(rng.below(4)) else @bitCast(rng.next());
    if (T == u64) return rng.nextU64();
    if (T == abi.Mod) return switch (rng.below(4)) {
        0 => f.a,
        1 => f.b,
        2 => .none,
        else => .{ .bits = rng.nextU64() },
    };
    if (T == abi.Entity) return if (rng.boolean()) entity else .{ .bits = rng.nextU64() };
    if (T == core.ContentId) return if (rng.boolean()) models.id("demo:models.pair") else .{ .hash = rng.nextU64() };
    if (T == d3.Instance) return if (rng.boolean()) f.instance else .{ .bits = rng.nextU64() };
    if (T == d3.Light) return if (rng.boolean()) f.light else .{ .bits = rng.nextU64() };
    if (T == d3.Body3D) return if (rng.boolean()) f.body else .{ .bits = rng.nextU64() };
    if (T == d3.Character) return if (rng.boolean()) f.character else .{ .bits = rng.nextU64() };
    var value: T = std.mem.zeroes(T);
    if (T == V) value = .{ .x = 1, .y = 0, .z = 0 };
    if (T == d3.Mat4) value = identity;
    if (T == d3.Transform) value = local;
    if (T == d3.Pose3D) value = at;
    if (T == d3.Shape3D) value = sphere;
    if (T == d3.Filter3D) value = filter;
    if (T == d3.Light3D) value = lamp;
    if (T == d3.Body3DDesc) value = body_desc;
    if (T == d3.CharacterConfig) value = config;
    switch (rng.below(4)) {
        0 => {}, // well-formed values reach downstream ownership/geometry checks
        1 => {
            for (std.mem.asBytes(&value)) |*byte| byte.* = @truncate(rng.next());
        },
        else => {
            const offsets = comptime floatOffsets(T, 0);
            if (offsets.len != 0) {
                const offset = offsets[rng.below(@intCast(offsets.len))];
                const poison = randomFloat(rng);
                @memcpy(std.mem.asBytes(&value)[offset..][0..4], std.mem.asBytes(&poison));
            } else for (std.mem.asBytes(&value)) |*byte| byte.* = @truncate(rng.next());
        },
    }
    return value;
}

fn sweepArgument(comptime T: type, comptime key: []const u8, rng: *Rng, f: *Fixture, entity: abi.Entity) T {
    if (@typeInfo(T) != .optional) return sweepValue(T, rng, f, entity);
    const info = @typeInfo(@typeInfo(T).optional.child).pointer;
    const Slot = struct {
        const unique = key; // separate storage for count/total and each call parameter
        var one: info.child = undefined;
        var many: [4096]info.child = undefined;
    };
    if (rng.below(5) == 0) return null;
    if (info.is_const) Slot.one = sweepValue(info.child, rng, f, entity) else Slot.one = sentinel(info.child);
    if (info.size == .many) {
        @memset(std.mem.sliceAsBytes(&Slot.many), 0x5a);
        return @as([*]info.child, &Slot.many);
    }
    return &Slot.one;
}

/// All writable storage, including the full overlap buffer and distinct count/total.
fn outputHash(args: anytype) u64 {
    var hash = std.hash.Wyhash.init(0);
    inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |param| {
        if (comptime @typeInfo(param.type) == .optional) {
            const info = @typeInfo(@typeInfo(param.type).optional.child).pointer;
            if (comptime !info.is_const) {
                if (@field(args, param.name)) |ptr| {
                    if (comptime info.size == .many) hash.update(std.mem.sliceAsBytes(ptr[0..4096])) else hash.update(std.mem.asBytes(ptr));
                }
            }
        }
    }
    return hash.final();
}

fn seededSweep(seed: u64) !void {
    @setEvalBranchQuota(100000);
    const f = try Fixture.init();
    defer f.deinit();
    try f.create();
    f.host.render3d_camera = testCamera();
    const before_body = f.collision.body(f.body.unwrap(physics.BodyHandle)).?.*;
    const before_feet = try playerReplay(f);
    const before_draw = try drawProtected(f);
    const entity: abi.Entity = .wrap(try f.world.create()); // legitimate hierarchy writes allowed
    var rng = Rng.init(seed, 25);
    var counts: [v6_fields.len]u32 = @splat(0);
    var accepted: u32 = 0;
    {
        const scope = f.host.enterCaller(f.b);
        defer scope.restore();
        for (0..10000) |iteration| {
            // Cycle entry points: all 28 are guaranteed, not probabilistically, to run.
            const selected = iteration % v6_fields.len;
            inline for (v6_fields, 0..) |field, index| {
                if (selected == index) {
                    const Fn = @typeInfo(field.type).pointer.child;
                    var args: std.meta.ArgsTuple(Fn) = undefined;
                    inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |param| {
                        @field(args, param.name) = sweepArgument(param.type, field.name ++ param.name, &rng, f, entity);
                    }
                    const outputs = outputHash(args);
                    const result = @call(.auto, @field(api, field.name), args);
                    counts[index] += 1;
                    // v6 has no iterator or duplicate-registration result, nor a valid
                    // internal-error path. A mapping gap is a failure, not accepted noise.
                    switch (result) {
                        .ok => accepted += 1,
                        .invalid_argument, .invalid_handle, .not_found, .unavailable, .unsupported, .limit, .refused, .out_of_memory => try t.expectEqual(outputs, outputHash(args)),
                        else => return error.UndocumentedSweepResult,
                    }
                }
            }
        }
    }
    for (counts) |count| try t.expect(count >= 357);
    try t.expect(accepted != 0);
    f.host.refuseMod(f.b);
    try t.expectEqual(before_body, f.collision.body(f.body.unwrap(physics.BodyHandle)).?.*);
    try t.expectEqual(before_feet, try playerReplay(f));
    try t.expectEqual(@as(?u64, f.a.bits), f.set.instanceOwner(f.instance.unwrap(render.InstanceHandle)));
    try t.expectEqual(@as(?u64, f.a.bits), f.set.lightOwner(f.light.unwrap(render.InstanceLightHandle)));
    for (f.host.bodies3d) |entry| if (!entry.handle.isNone()) try t.expect(entry.owner.eql(f.a));
    for (f.host.characters3d) |entry| if (!entry.handle.isNone()) try t.expect(entry.owner.eql(f.a));
    try t.expectEqual(before_draw, try drawProtected(f));
}

test "M25 v6 seeded argument sweep 0x25" {
    try seededSweep(0x25);
}
test "M25 v6 seeded argument sweep 0x5eed1234" {
    try seededSweep(0x5eed1234);
}
test "M25 v6 seeded argument sweep 0xdeadbeefcafebabe" {
    try seededSweep(0xdeadbeefcafebabe);
}

test "M25 v6 hostile native init preserves foreign objects and failed init sweeps its own" {
    const f = try Fixture.init();
    defer f.deinit();
    // Reuse the already-proven animation file generator, without publishing animation.
    const animated = try models.animationStack(1, 1, models.animation_records);
    defer animated.deinit();
    for ([_][]const u8{ "skin/mesh.fmesh", "skin/rig.fskel", "skin/walk.fanim" }) |file| {
        const source = try platform.os.joinPath(t.allocator, &.{ animated.out, file });
        defer t.allocator.free(source);
        const bytes = try animated.os.readFile(t.allocator, source, 1 << 20);
        defer t.allocator.free(bytes);
        try f.stack.install(file, bytes);
    }
    try f.stack.write("skin.fdt", models.animation_records);
    try f.stack.build();
    try f.create();
    f.host.render3d_camera = testCamera();
    const floor = try f.collision.addBody(t.allocator, .{ .shape = .{ .box = .{ .half_extents = .init(20, 0.5, 20) } }, .pose = .at(.init(0, -0.5, 0)), .layer = 1, .mask = ~@as(u32, 0), .user = 999 });
    const host_desc = f.collision.body(floor).?.*;
    const foreign_desc = f.collision.body(f.body.unwrap(physics.BodyHandle)).?.*;
    const e = try f.world.create();
    const state = f.world.hierarchy.?;
    const transform: scene.hierarchy.Transform = .{};
    _ = try f.world.addComponent(e, state.types.transform, std.mem.asBytes(&transform));
    var chain: [4]scene.Entity = undefined;
    for (&chain, 0..) |*node, index| {
        node.* = try f.world.create();
        _ = try f.world.addComponent(node.*, state.types.transform, std.mem.asBytes(&transform));
        if (index != 0) try scene.hierarchy.setParent(&f.world, node.*, chain[index - 1]);
    }
    const singular = try f.world.create();
    var zero_scale = transform;
    zero_scale.scale.x = 0;
    _ = try f.world.addComponent(singular, state.types.transform, std.mem.asBytes(&zero_scale));
    const scaled = try f.world.create();
    var nonuniform = transform;
    nonuniform.scale.x = 2;
    nonuniform.rotation = core.math.Quat.fromAxisAngle(core.math.Vec3.up, std.math.pi / 4.0);
    _ = try f.world.addComponent(scaled, state.types.transform, std.mem.asBytes(&nonuniform));
    const sheared = try f.world.create();
    var rotated = transform;
    rotated.rotation = core.math.Quat.fromAxisAngle(core.math.Vec3.up, std.math.pi / 4.0);
    _ = try f.world.addComponent(sheared, state.types.transform, std.mem.asBytes(&rotated));
    try scene.hierarchy.setParent(&f.world, sheared, scaled);
    const hull = try f.collision.addHull(t.allocator, &.{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0), .init(0, 0, 1) });
    const hull_handle = try f.collision.addBody(t.allocator, .{ .shape = .{ .hull = hull }, .pose = .at(.init(100, 0, 0)) });
    _ = try scene.hierarchy.propagate(&f.world);
    const derived = scene.hierarchy.worldTransform(&f.world, e).?;
    const before_hierarchy = try hierarchySnapshot(f);
    defer t.allocator.free(before_hierarchy);
    const before_bodies = f.collision.bodyCount();
    const held = .{ f.stack.content.models.count(), f.stack.content.materials.count() };
    const replay = try playerReplay(f);
    const before_draw = try drawProtected(f);
    const path = try stageLibrary(f, options.hostile3d_mod_path, "hostile3d_mod");
    defer t.allocator.free(path);
    // Configure the real image without invoking an ABI call or granting caller authority.
    var image = try platform.os.Library.open(t.allocator, path);
    defer image.close();
    const Configure = *const fn (d3.Instance, d3.Light, d3.Body3D, d3.Character, d3.Body3D, abi.Entity, abi.Mod) callconv(.c) void;
    image.symbol(Configure, "foundry_test_targets").?(f.instance, f.light, f.body, f.character, .wrap(floor), .wrap(e), f.a);
    const Extra = *const fn (abi.Entity, abi.Entity, abi.Entity, d3.Body3D) callconv(.c) void;
    image.symbol(Extra, "foundry_test_extra").?(.wrap(chain[3]), .wrap(singular), .wrap(sheared), .wrap(hull_handle));
    var loader = abi.NativeLoaderOf(abi.Host).init(t.allocator, &f.host);
    defer loader.deinit();
    try loadNative(f, &loader, "hostile3d_mod");
    const loaded = &loader.loaded.items[0];
    try t.expect(f.host.modId(loaded.self) == null); // deliberate refused init
    try t.expectEqual(@as(usize, 1), f.stack.diags.count());
    const Probe = *const fn () callconv(.c) u32;
    try t.expect(loaded.library.symbol(Probe, "foundry_test_calls").?() > 600);
    try t.expect(f.host.caller() == null);
    try t.expectEqual(host_desc, f.collision.body(floor).?.*);
    try t.expectEqual(foreign_desc, f.collision.body(f.body.unwrap(physics.BodyHandle)).?.*);
    try unchanged(scene.hierarchy.Transform, transform, std.mem.bytesToValue(scene.hierarchy.Transform, f.world.readComponent(e, state.types.transform).?));
    try t.expectEqual(derived, scene.hierarchy.worldTransform(&f.world, e).?);
    try t.expect(scene.hierarchy.parentOf(&f.world, e) == null);
    const after_hierarchy = try hierarchySnapshot(f);
    defer t.allocator.free(after_hierarchy);
    try t.expectEqualSlices(u8, before_hierarchy, after_hierarchy);
    try t.expectEqual(before_bodies, f.collision.bodyCount());
    try t.expectEqual(held, .{ f.stack.content.models.count(), f.stack.content.materials.count() });
    for (f.host.bodies3d) |entry| if (!entry.handle.isNone()) try t.expect(entry.owner.eql(f.a));
    for (f.host.characters3d) |entry| if (!entry.handle.isNone()) try t.expect(entry.owner.eql(f.a));
    try t.expectEqual(replay, try playerReplay(f));
    try t.expectEqual(before_draw, try drawProtected(f));
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
