//! Use the actual fpack output, not a hand-recreated level.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const anim = @import("anim");
const app = @import("app");
const asset = @import("asset");
const platform = @import("platform");
const walk_mod = @import("walk.zig");
const Settings = @import("settings.zig").Settings;
const options = @import("court_test_options");
const testing = std.testing;
const dt: f32 = core.time.Timestep.fromHz(60).elapsedAt(1).toSecondsF32();

test "court: compiled level blocks walking, jumps the low wall and lands; airborne jump is refused" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const os = try platform.os.Os.init(gpa, .{});
    defer os.deinit();
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var schemas: data.Registry = .init(gpa, .default);
    defer schemas.deinit(gpa);
    try asset.schemas.registerAll(gpa, &schemas);
    var store: data.Store = .init(gpa, .default);
    defer store.deinit(gpa);
    const base = try os.readFile(gpa, options.core_package, 16 * 1024 * 1024);
    defer gpa.free(base);
    _ = try store.add(gpa, "foundry:core", base, &schemas, &diags);
    const bytes = try os.readFile(gpa, options.package, 16 * 1024 * 1024);
    defer gpa.free(bytes);
    const package = try store.add(gpa, "court:content", bytes, &schemas, &diags);
    const config = try Settings.read(store.lookup(core.ContentId.fromString("court:config.main")).?);
    const config_record = store.lookup(core.ContentId.fromString("court:config.main")).?;
    const config_block = try gpa.dupe(u8, config_record.fields.block);
    defer gpa.free(config_block);
    var bad_config = config_record;
    bad_config.fields.block = config_block;
    const width_offset = fieldOffset(config_record.fields.fields, config_record.schema.fieldIndex("window_width").?);
    std.mem.writeInt(u32, config_block[width_offset..][0..4], 0, .little);
    try testing.expectError(error.InvalidConfig, Settings.read(bad_config));
    const clear_list = (try config_record.fields.listAt(config_record.schema.fieldIndex("clear_linear").?)).?;
    const clear_bytes = @constCast(clear_list.bytes);
    const old_clear: [4]u8 = clear_bytes[0..4].*;
    std.mem.writeInt(u32, clear_bytes[0..4], @bitCast(std.math.nan(f32)), .little);
    try testing.expectError(error.InvalidConfig, Settings.read(config_record));
    @memcpy(clear_bytes[0..4], &old_clear);
    try testing.expectEqual(@as(usize, 1), config.lighting.len);
    try testing.expect(config.lighting.lights[0].casts_shadow);
    try testing.expect(config.level.eql(core.ContentId.fromString("court:models.court")));
    var assets = asset.Registry.init(gpa, os, &store, .{});
    defer assets.deinit(gpa);
    try assets.mount(gpa, package, options.generated);
    try assets.registerLoader(gpa, asset.collisionMeshLoader());
    var walk = walk_mod.Walk.init(gpa);
    defer walk.deinit(&assets);
    walk.refresh(&store, &assets, dt);
    try testing.expect(!walk.character.isNone());
    try testing.expect(!walk.collisions[0].body.isNone());
    for (0..5) |_| try walk.step(.{}, dt);
    try testing.expect(walk.result.grounded);
    // Walking east cannot pass the courtyard wall.
    for (0..150) |_| try walk.step(.{ .direction = .right }, dt);
    try testing.expect(walk.result.feet.x > 5 and walk.result.feet.x < 6);
    try testing.expect(walk.result.grounded and !walk.result.stuck);
    // A 0.65m wall exceeds step_height. Ordinary walking stops; a jump crosses.
    try walk.teleport(.init(-3, 0.004, 2));
    for (0..25) |_| try walk.step(.{ .direction = .forward }, dt);
    try testing.expect(walk.result.feet.z > 1.4);
    try walk.step(.{ .direction = .forward, .jump = true }, dt);
    try testing.expect(walk.velocity > 0 and !walk.result.grounded);
    const velocity = walk.velocity;
    try walk.step(.{ .direction = .forward, .jump = true }, dt);
    try testing.expect(walk.velocity < velocity); // No double jump.
    var highest = walk.result.feet.y;
    for (0..65) |_| {
        try walk.step(.{ .direction = .forward }, dt);
        highest = @max(highest, walk.result.feet.y);
    }
    try testing.expect(highest > 1);
    try testing.expect(walk.result.feet.z < 0.5 and walk.result.grounded);
    // Captured relative look is applied by a tick, and pitch stays bounded.
    try walk.step(.{ .look_dx = 10, .look_dy = -10000 }, dt);
    try testing.expect(walk.yaw > 0);
    try testing.expectApproxEqAbs(@as(f32, 85 * std.math.pi / 180.0), walk.pitch, 1e-6);
    // Jump spans the courtyard gap and lands on the far ledge.
    try walk.teleport(.init(0, 0.004, -1.5));
    for (0..5) |_| try walk.step(.{}, dt);
    try walk.step(.{ .jump = true }, dt);
    walk.yaw = 0;
    for (0..65) |_| try walk.step(.{ .direction = .forward }, dt);
    try testing.expect(walk.result.feet.z < -3.3 and walk.result.grounded);
    const old = walk.collisions[0].body;
    const feet = walk.result.feet;
    walk.refresh(&store, &assets, dt);
    try testing.expect(walk.world.body(old) == null);
    try testing.expectEqualDeep(feet, walk.result.feet);
}

test "court: input edges survive empty frames and occur once across catch-up ticks" {
    var input: platform.InputSnapshot = .{};
    platform.key.setKey(&input.keys_pressed, .space, true);
    input.mouse.captured = true;
    input.mouse.motion = .{ .x = 10, .y = -2 };
    var pending: walk_mod.Pending = .{};
    pending.feed(walk_mod.inputIntent(input, false));
    pending.feed(.{ .direction = .right, .look_dx = 3 });
    const first = pending.take();
    try testing.expect(first.jump);
    try testing.expectEqual(@as(f32, 13), first.look_dx);
    try testing.expectEqual(@as(f32, -2), first.look_dy);
    const second = pending.take();
    try testing.expect(!second.jump and second.look_dx == 0 and second.look_dy == 0);
    try testing.expectEqualDeep(core.math.Vec3.right, second.direction);
    input.mouse.captured = false;
    try testing.expectEqual(@as(f32, 0), walk_mod.inputIntent(input, false).look_dx);
    try testing.expectEqualDeep(walk_mod.Intent{}, walk_mod.inputIntent(input, true));
}

test "court: package movement rules refuse missing, non-finite and out-of-bounds fields" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const os = try platform.os.Os.init(gpa, .{});
    defer os.deinit();
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var schemas: data.Registry = .init(gpa, .default);
    defer schemas.deinit(gpa);
    try asset.schemas.registerAll(gpa, &schemas);
    var store: data.Store = .init(gpa, .default);
    defer store.deinit(gpa);
    const base = try os.readFile(gpa, options.core_package, 16 * 1024 * 1024);
    defer gpa.free(base);
    _ = try store.add(gpa, "foundry:core", base, &schemas, &diags);
    const bytes = try os.readFile(gpa, options.package, 16 * 1024 * 1024);
    defer gpa.free(bytes);
    _ = try store.add(gpa, "court:content", bytes, &schemas, &diags);
    const fields = store.lookup(core.ContentId.fromString("court:rules.main")).?.fields;
    _ = try walk_mod.Settings.read(fields, dt);
    try testing.expectError(error.InvalidWalk, walk_mod.Settings.read(fields, 0));
    const block = try gpa.dupe(u8, fields.block);
    defer gpa.free(block);
    var edited = fields;
    edited.block = block;
    for (fields.fields, 0..) |field, i| {
        @memcpy(block, fields.block);
        block[i / 8] &= ~(@as(u8, 1) << @intCast(i % 8));
        try testing.expectError(error.InvalidWalk, walk_mod.Settings.read(edited, dt));
        if (field.type == .f32) {
            const offset = fieldOffset(fields.fields, i);
            for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.floatMax(f32), std.math.floatMax(f32) }) |v| {
                @memcpy(block, fields.block);
                std.mem.writeInt(u32, block[offset..][0..4], @bitCast(v), .little);
                try testing.expectError(error.InvalidWalk, walk_mod.Settings.read(edited, dt));
            }
        }
    }
    for ([_]f32{ 0, -1, 31 }) |speed| {
        @memcpy(block, fields.block);
        const offset = fieldOffset(fields.fields, store.lookup(core.ContentId.fromString("court:rules.main")).?.schema.fieldIndex("jump_speed").?);
        std.mem.writeInt(u32, block[offset..][0..4], @bitCast(speed), .little);
        try testing.expectError(error.InvalidWalk, walk_mod.Settings.read(edited, dt));
    }
}

fn fieldOffset(fields: []const data.schema.Field, index: usize) usize {
    var cursor: usize = data.fpk.presenceBytes(fields.len);
    for (fields, 0..) |field, i| {
        cursor = std.mem.alignForward(usize, cursor, data.fpk.alignOf(field.type));
        if (i == index) return cursor;
        cursor += data.fpk.sizeOf(field.type);
    }
    unreachable;
}

test "warden: M34's and M35's clips are appended, and old bytes stay" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const os = try platform.os.Os.init(gpa, .{});
    defer os.deinit();
    // What every clip before M35's, the mesh and the skeleton compile to, from before M35 appended its
    // four (`animation-states.md` §12). The walker and the warden share them, and both models have
    // M35's four after them.
    for ([_][]const u8{ "clip0.fanim", "clip1.fanim", "clip2.fanim", "clip3.fanim", "clip4.fanim", "clip5.fanim", "clip6.fanim", "mesh0.fmesh", "skeleton0.fskel", "clip7.fanim", "clip8.fanim", "clip9.fanim", "clip10.fanim" }, [_]u64{ 0x1f2fa1d2d86042df, 0x5f966564dd9529be, 0x677f6e68ba41d452, 0xd6ea268c1b779558, 0x713aa9b4e2b9b0de, 0xa6f9a2d5f8bffd30, 0x84900a520fa63575, 0xeeef08a437cd77d7, 0xbb4e02a8a82029cb, 0x142f09c2287a2525, 0xdc62c95899a438d9, 0x39e40914d0fd57e7, 0x43a9fdfc1d1ae389 }) |name, pin| {
        const path = try std.fs.path.join(gpa, &.{ options.generated, "models/warden", name });
        defer gpa.free(path);
        const bytes = try os.readFile(gpa, path, 1024 * 1024);
        defer gpa.free(bytes);
        try testing.expectEqual(pin, std.hash.Fnv1a_64.hash(bytes));
    }
}

test "warden: M35's clips build a version 2 rig: a run in step with the stride, an upper mask, two additive clips and a climb's rise" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const engine = try app.Engine.init(gpa, .{ .headless = true, .workers = 0, .content_dir = options.generated, .content = &.{
        .{ .base_dir = std.fs.path.dirname(options.core_package).?, .file = std.fs.path.basename(options.core_package), .root = "core-assets" },
        .{ .base_dir = std.fs.path.dirname(options.package).?, .file = std.fs.path.basename(options.package), .root = "court-assets" },
    } });
    defer engine.deinit();
    var rigs = asset.Rigs.init(gpa, &engine.assets);
    defer rigs.deinit();
    const handle = try rigs.acquire(core.ContentId.fromString("court:warden.set"));
    defer rigs.release(handle);
    const rig = rigs.get(handle).?;
    try testing.expectEqual(@as(usize, 11), rig.clips.len);

    // `run` covers its 1.3 m in 0.7 s, and keeps a foot in step with the stride's.
    const run = rig.find(anim.clipName("run")).?;
    try testing.expect(run.motion and run.loop);
    try testing.expectApproxEqAbs(@as(f32, 0.7), run.clip.duration, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.3 / 0.7), rig.motionSpeed(anim.clipName("run")), 1e-4);
    try testing.expectEqual(@as(usize, 2), run.events.len);
    try testing.expectEqual(anim.clipName("feet"), run.sync);
    try testing.expectEqual(anim.clipName("feet"), rig.find(anim.clipName("stride")).?.sync);

    // `reach` touches the upper body alone: no track below the spine.
    const skeleton = rig.skeleton;
    const spine: u16 = 1;
    for (rig.find(anim.clipName("reach")).?.clip.tracks) |track| {
        var joint = track.joint;
        while (joint != spine) {
            joint = skeleton.parents[joint];
            try testing.expect(joint != anim.no_parent);
        }
    }

    // `upper` is the spine at half and everything from the chest up at full; the legs are out.
    const upper = rig.mask(anim.clipName("upper")).?;
    try testing.expectEqualStrings("upper", upper.label);
    for ([_]u16{ 0, 1, 2, 4, 5, 8, 9, 13, 14, 16 }, [_]f32{ 0, 0.5, 1, 1, 1, 1, 1, 0, 0, 0 }) |joint, weight| {
        try testing.expectEqual(weight, upper.weights[joint]);
    }

    // `pant` and `look` are differences from their own first frames, which are at rest.
    for ([_][]const u8{ "pant", "look" }) |name| {
        const entry = rig.find(anim.clipName(name)).?;
        try testing.expect(entry.additive and !entry.motion);
        try testing.expectEqual(skeleton.jointCount(), entry.reference.len);
        for (entry.reference, skeleton.rest) |reference, at_rest| {
            try testing.expectApproxEqAbs(@as(f32, 0), reference.translation.sub(at_rest.translation).length(), 1e-6);
            try testing.expectApproxEqAbs(@as(f32, 1), @abs(reference.rotation.dot(at_rest.rotation)), 1e-6);
        }
    }

    // A climb rises 0.3 m a lap, so 3 m is ten laps.
    try testing.expectEqual(@as(f32, 0.3), rig.find(anim.clipName("climb")).?.rise);
    try testing.expectEqual(@as(u32, 10), rig.lapsFor(anim.clipName("climb"), 3));
}
