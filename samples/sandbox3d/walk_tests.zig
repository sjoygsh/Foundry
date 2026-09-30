//! Package-to-controller integration, not a hand-recreated course.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const platform = @import("platform");
const physics = @import("physics3d");
const walk_mod = @import("walk.zig");
const Tour = @import("tour.zig").Tour;
const options = @import("walk_test_options");
const testing = std.testing;
const dt: f32 = core.time.Timestep.fromHz(60).elapsedAt(1).toSecondsF32();

test "walk tour: compiled room and course pass all five stages and byte-exact fresh-world replay" {
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
    const package = try os.readFile(gpa, options.package, 16 * 1024 * 1024);
    defer gpa.free(package);
    const handle = try store.add(gpa, "sandbox3d:content", package, &schemas, &diags);
    var assets = asset.Registry.init(gpa, os, &store, .{});
    defer assets.deinit(gpa);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try tmp.dir.realPath(testing.io, &path_buffer);
    const root = path_buffer[0..path_length];
    const config = try walk_mod.Settings.read(store.lookup(core.ContentId.fromString("sandbox3d:walk.main")).?.fields, dt);
    for (config.collision[0..config.len]) |id| {
        const record = store.lookup(id).?;
        const source = (try record.fields.stringAt(record.schema.fieldIndex("source").?)).?;
        const read = try os.readFileConfined(gpa, options.generated, source, asset.collision_mesh.Limits.default.max_file_bytes);
        defer gpa.free(read.bytes);
        const target = try platform.os.joinPath(gpa, &.{ root, source });
        defer gpa.free(target);
        try os.createDirPath(std.fs.path.dirname(target).?);
        try os.writeFile(target, read.bytes);
    }
    try assets.mount(gpa, handle, root);
    try assets.registerLoader(gpa, asset.collisionMeshLoader());
    var first = walk_mod.Walk.init(gpa);
    defer first.deinit(&assets);
    first.refresh(&store, &assets, dt);
    try testing.expect(!first.character.isNone());
    try testing.expectEqual(@as(usize, 2), first.settings.?.len);
    try testing.expect(!first.collisions[0].body.isNone() and !first.collisions[1].body.isNone());
    var tour: Tour = .{};
    while (!tour.done()) try tour.advance(&first, dt);
    try testing.expect(tour.failed == null);
    var replay = walk_mod.Walk.init(gpa);
    defer replay.deinit(&assets);
    replay.refresh(&store, &assets, dt);
    var second: Tour = .{ .emit = false };
    while (!second.done()) try second.advance(&replay, dt);
    try testing.expect(tour.replayMatches(&second));

    // Refresh replaces copied bodies/meshes without teleporting an unchanged character.
    const feet = first.result.feet;
    const character = first.character;
    const old_body = first.collisions[1].body;
    first.refresh(&store, &assets, dt);
    try testing.expectEqualDeep(character, first.character);
    try testing.expectEqualDeep(feet, first.result.feet);
    try testing.expect(first.world.body(old_body) == null);
    try first.step(.{}, dt);
    try testing.expect(!first.result.stuck);

    // A real source reload raises the platform into the character. Residency is replaced;
    // the very next ordinary tick depenetrates the old feet onto the changed geometry.
    try first.teleport(.init(-1.3, 0.6 + physics.contact_skin, -2.1));
    try first.step(.{}, dt);
    const course_id = config.collision[1];
    const record = store.lookup(course_id).?;
    const source = (try record.fields.stringAt(record.schema.fieldIndex("source").?)).?;
    const read = try os.readFileConfined(gpa, root, source, asset.collision_mesh.Limits.default.max_file_bytes);
    defer gpa.free(read.bytes);
    var geometry = try (try asset.collision_mesh.read(read.bytes, .default)).copy(gpa);
    defer geometry.deinit(gpa);
    for (geometry.positions) |*position| position.y += 0.1;
    const changed = try asset.collision_mesh.write(gpa, geometry.positions, geometry.indices);
    defer gpa.free(changed);
    const path = try platform.os.joinPath(gpa, &.{ root, source });
    defer gpa.free(path);
    try os.writeFile(path, changed);
    try assets.reload(gpa, first.collisions[1].handle);
    first.refresh(&store, &assets, dt);
    try testing.expectEqualDeep(character, first.character);
    try first.step(.{}, dt);
    try testing.expect(first.result.depenetrated and first.result.grounded and first.result.feet.y >= 0.7);

    // Missing named collision is omitted rather than keeping a cached old body or failing.
    const walk_record = store.lookup(core.ContentId.fromString("sandbox3d:walk.main")).?;
    const list = (try walk_record.fields.listAt(walk_record.schema.fieldIndex("collision").?)).?;
    const writable = @constCast(list.bytes);
    const original: [8]u8 = writable[8..16].*;
    std.mem.writeInt(u64, writable[8..16], core.ContentId.fromString("sandbox3d:missing.collision").hash, .little);
    first.refresh(&store, &assets, dt);
    try testing.expect(first.collisions[1].body.isNone() and !first.collisions[0].body.isNone());
    @memcpy(writable[8..16], &original);
    // No record at all disables the whole walk and retires its character and residency.
    var empty: data.Store = .init(gpa, .default);
    defer empty.deinit(gpa);
    const old_character = first.character;
    first.refresh(&empty, &assets, dt);
    try testing.expect(first.orbit and first.character.isNone() and first.settings == null);
    try testing.expect(first.world.character(old_character) == null);
}

test "walk settings: every field and list is validated; invalid data disables the whole walk" {
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
    _ = try store.add(gpa, "sandbox3d:content", bytes, &schemas, &diags);
    const fields = store.lookup(core.ContentId.fromString("sandbox3d:walk.main")).?.fields;
    const good = try walk_mod.Settings.read(fields, dt);
    try testing.expect(!good.orbit);
    try testing.expectEqual(@as(f32, 1), good.character.max_move);
    try testing.expectError(error.InvalidWalk, walk_mod.Settings.read(fields, std.math.nan(f32)));
    const block = try gpa.dupe(u8, fields.block);
    defer gpa.free(block);
    var edited = fields;
    edited.block = block;
    for (fields.fields, 0..) |field, i| {
        // Every missing field refuses the record, including formerly-defaulted fields.
        @memcpy(block, fields.block);
        block[i / 8] &= ~(@as(u8, 1) << @intCast(i % 8));
        try testing.expectError(error.InvalidWalk, walk_mod.Settings.read(edited, dt));
        if (field.type == .f32) {
            const offset = fieldOffset(fields.fields, i);
            for ([_]f32{ std.math.nan(f32), std.math.inf(f32), std.math.floatMax(f32), -std.math.floatMax(f32) }) |value| {
                @memcpy(block, fields.block);
                std.mem.writeInt(u32, block[offset..][0..4], @bitCast(value), .little);
                try testing.expectError(error.InvalidWalk, walk_mod.Settings.read(edited, dt));
            }
        } else if (field.type == .nested) {
            const offset = fieldOffset(fields.fields, i);
            for (field.type.nested, 0..) |_, n| {
                const at = offset + fieldOffset(field.type.nested, n);
                for ([_]f32{ std.math.nan(f32), std.math.inf(f32), 8193 }) |value| {
                    @memcpy(block, fields.block);
                    std.mem.writeInt(u32, block[at..][0..4], @bitCast(value), .little);
                    try testing.expectError(error.InvalidWalk, walk_mod.Settings.read(edited, dt));
                }
            }
        } else if (field.type == .id) {
            @memcpy(block, fields.block);
            const at = fieldOffset(fields.fields, i);
            std.mem.writeInt(u64, block[at..][0..8], 0, .little);
            try testing.expectError(error.InvalidWalk, walk_mod.Settings.read(edited, dt));
        } else if (field.type == .list) {
            for ([_]u32{ 0, walk_mod.Settings.max_collision + 1 }) |count| {
                @memcpy(block, fields.block);
                const at = fieldOffset(fields.fields, i);
                std.mem.writeInt(u32, block[at + 4 ..][0..4], count, .little);
                try testing.expectError(error.InvalidWalk, walk_mod.Settings.read(edited, dt));
            }
            const list = (try fields.listAt(@intCast(i))).?;
            const writable = @constCast(list.bytes);
            const original: [8]u8 = writable[8..16].*;
            @memcpy(writable[8..16], writable[0..8]);
            try testing.expectError(error.InvalidWalk, walk_mod.Settings.read(fields, dt));
            @memcpy(writable[8..16], &original);
        } else if (field.type == .string) {
            const mode = @constCast((try fields.stringAt(@intCast(i))).?);
            const original = mode[0];
            mode[0] = 'x';
            try testing.expectError(error.InvalidWalk, walk_mod.Settings.read(fields, dt));
            mode[0] = original;
        }
    }
    var bad = good;
    bad.eye_height = 2;
    try testing.expect(!bad.valid());
    bad = good;
    bad.spawn.y = 8192;
    try testing.expect(!bad.valid());
    bad = good;
    bad.character.radius = 0;
    try testing.expect(!bad.valid());
}

/// Test-only field-block layout, using the public format's size/alignment functions.
fn fieldOffset(fields: []const data.schema.Field, index: usize) usize {
    var cursor: usize = data.fpk.presenceBytes(fields.len);
    for (fields, 0..) |field, i| {
        cursor = std.mem.alignForward(usize, cursor, data.fpk.alignOf(field.type));
        if (i == index) return cursor;
        cursor += data.fpk.sizeOf(field.type);
    }
    unreachable;
}
