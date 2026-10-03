//! Use the actual fpack output, not a hand-recreated level.
const std = @import("std");
const core = @import("core");
const data = @import("data");
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
