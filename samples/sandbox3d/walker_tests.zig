//! Compiled package -> renderer/model handles -> patrol -> poses, reload and replay.
const std = @import("std");
const builtin = @import("builtin");
const app = @import("app");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const render3d = @import("render3d");
const platform = @import("platform");
const walker_mod = @import("walker.zig");
const Walker = walker_mod.Walker;
const Walk = @import("walk.zig").Walk;
const Tour = @import("tour.zig").Tour;
const options = @import("walk_test_options");
const testing = std.testing;
const dt = core.time.Timestep.fromHz(60).elapsedAt(1).toSecondsF32();

test "walker: compiled patrol, both clips, cross-fade, fresh-world replay and unchanged player hash" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const engine = try app.Engine.init(gpa, .{ .headless = true, .workers = 0, .content_dir = options.generated, .content = &.{
        .{ .base_dir = std.fs.path.dirname(options.core_package).?, .file = std.fs.path.basename(options.core_package), .root = "core-assets" },
        .{ .base_dir = std.fs.path.dirname(options.package).?, .file = std.fs.path.basename(options.package), .root = "sandbox3d-assets" },
    } });
    defer engine.deinit();
    try engine.assets.registerLoader(gpa, asset.collisionMeshLoader());
    var renderer = try render3d.Renderer.init(gpa, engine.gpu, .{});
    defer renderer.deinit();
    var content = render3d.Content.init(gpa, &renderer, &engine.assets, .default);
    defer content.deinit();
    var first = Walk.init(gpa);
    defer first.deinit(&engine.assets);
    first.refresh(&engine.store, &engine.assets, dt);
    var walker: Walker = .{};
    defer walker.deinit(gpa, &first.world, &content);
    try walker.refresh(gpa, &engine.store, &first.world, &content, dt);
    try testing.expectEqual(@as(usize, 19), walker.joint_count);
    // Refuse changed borrowed values before entering anim's programmer-only assertions.
    const live_clip = @constCast(content.clipOf(walker.model, "idle").?);
    const saved_count = live_clip.joint_count;
    live_clip.joint_count = 1;
    try testing.expectError(error.SkeletonMismatch, walker.evaluate(&content, dt));
    try testing.expectEqual(@as(usize, 0), walker.joint_count);
    live_clip.joint_count = saved_count;
    const saved_tracks = live_clip.tracks;
    var too_many: [769]asset.animation.Track = undefined;
    live_clip.tracks = &too_many;
    const too_many_result = walker.evaluate(&content, dt);
    live_clip.tracks = saved_tracks;
    try testing.expectError(error.TooManyTracks, too_many_result);
    const saved_duration = live_clip.duration;
    live_clip.duration = 0;
    const bad_duration_result = walker.evaluate(&content, dt);
    live_clip.duration = saved_duration;
    try testing.expectError(error.InvalidDuration, bad_duration_result);
    const live_rig = @constCast(content.skeletonOf(walker.model).?);
    live_rig.root.cols[0][3] = 1;
    try testing.expectError(error.InvalidRoot, walker.evaluate(&content, dt));
    live_rig.root.cols[0][3] = 0;
    try walker.evaluate(&content, dt);
    var tour: Tour = .{ .emit = false };
    var second = Walk.init(gpa);
    defer second.deinit(&engine.assets);
    second.refresh(&engine.store, &engine.assets, dt);
    var replay: Walker = .{};
    defer replay.deinit(gpa, &second.world, &content);
    try replay.refresh(gpa, &engine.store, &second.world, &content, dt);
    for (0..Walker.proof_ticks) |_| {
        if (!tour.done()) try tour.advance(&first, dt);
        try walker.move(gpa, &first.world, dt);
        try walker.evaluate(&content, dt);
        walker.record();
        try replay.move(gpa, &second.world, dt);
        try replay.evaluate(&content, dt);
        replay.record();
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(walker.pose[0..walker.joint_count]), std.mem.sliceAsBytes(replay.pose[0..replay.joint_count]));
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(walker.matrices[0..walker.joint_count]), std.mem.sliceAsBytes(replay.matrices[0..replay.joint_count]));
        try testing.expectEqual(walker.hash, replay.hash);
    }
    try testing.expect(walker.proofPassed() and replay.proofPassed());
    try testing.expect(tour.failed == null and tour.done());
    try testing.expectEqual(@as(u64, 0xcb99ccfcf2b6d6c3), tour.hash);
    // Same-binary replay is exact. The platform/build-specific pin is recorded after the
    // sample's generated clips, movement and palette have all contributed.
    if (builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos)
        try testing.expectEqual(@as(u64, if (builtin.mode == .Debug) 0x62ed8c026c20482c else 0xfa431d9440d4cb2e), walker.hash);
    const feet = walker.feet;
    const tick = walker.tick;
    const old_character = walker.character;
    try walker.refresh(gpa, &engine.store, &first.world, &content, dt);
    try testing.expectEqualDeep(feet, walker.feet);
    try testing.expectEqual(tick, walker.tick);
    try testing.expect(first.world.character(old_character) == null);
    // A changed patrol record restarts playback/proof, unlike an unchanged asset refresh.
    const patrol = engine.store.lookup(core.ContentId.fromString("sandbox3d:walker.main")).?;
    const editable = @constCast(patrol.fields.block);
    const speed_offset = editable.len - 8;
    const saved_speed: [4]u8 = editable[speed_offset..][0..4].*;
    std.mem.writeInt(u32, editable[speed_offset..][0..4], @bitCast(@as(f32, 0.7)), .little);
    try walker.refresh(gpa, &engine.store, &first.world, &content, dt);
    try testing.expectEqual(@as(u64, 0), walker.tick);
    try testing.expectEqual(@as(u32, 0), walker.reached);
    try testing.expect(!walker.used_walk and !walker.used_fade);
    try testing.expectEqual(@as(u64, 0xcbf29ce484222325), walker.hash);
    @memcpy(editable[speed_offset..][0..4], &saved_speed);
    try walker.refresh(gpa, &engine.store, &first.world, &content, dt);
    // Ordinary submissions copy the freshly evaluated palette, including after refresh.
    try renderer.begin(.{ .camera = .{}, .target_size = .{ .width = 64, .height = 64 } });
    try walker.draw(&content, .zero);
    // Redirect this package's ordinary mount to scratch; never alter build-owned outputs.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buffer);
    const root = path_buffer[0..path_len];
    const names = [_][]const u8{ "sandbox3d:models.walker.mesh0", "sandbox3d:models.walker.skeleton", "sandbox3d:models.walker.clip0", "sandbox3d:models.walker.clip1" };
    for (names) |name| {
        const source = try sourceOf(&engine.store, name);
        const original = try engine.os.readFileConfined(gpa, options.generated, source, 1024 * 1024);
        defer gpa.free(original.bytes);
        const target = try platform.os.joinPath(gpa, &.{ root, source });
        defer gpa.free(target);
        try engine.os.createDirPath(std.fs.path.dirname(target).?);
        try engine.os.writeFile(target, original.bytes);
    }
    try engine.assets.mount(gpa, engine.store.findPackage(core.ContentId.fromString("sandbox3d:content")).?, root);
    // A valid changed rig shifts every palette; a changed clip changes its sampled pose.
    const rig = content.skeletonOf(walker.model).?;
    var translated = rig.root;
    translated.cols[3][0] += 0.02;
    const rig_bytes = try asset.skeleton.write(gpa, .{ .parents = rig.parents, .rest = rig.rest, .inverse_bind = rig.inverse_bind, .root = translated, .names = rig.names });
    defer gpa.free(rig_bytes);
    const before_matrix = walker.matrices[0];
    try replace(&engine.assets, &engine.store, engine.os, root, names[1], rig_bytes);
    try walker.refresh(gpa, &engine.store, &first.world, &content, dt);
    try testing.expect(!std.meta.eql(before_matrix, walker.matrices[0]));
    const clip_bytes = try asset.animation.write(gpa, .{ .duration = 1, .joint_count = @intCast(walker.joint_count), .tracks = &.{.{ .joint = 1, .path = .rotation, .times = &.{ 0, 1 }, .values = &.{ 0.09983342, 0, 0, 0.9950042, 0.09983342, 0, 0, 0.9950042 } }} });
    defer gpa.free(clip_bytes);
    const before_pose = walker.pose[1];
    try replace(&engine.assets, &engine.store, engine.os, root, names[2], clip_bytes);
    try walker.refresh(gpa, &engine.store, &first.world, &content, dt);
    try testing.expect(!std.meta.eql(before_pose, walker.pose[1]));
    // A source mesh reload retires its old resident handle. The ordinary Content seam
    // reconnects parts, and a refreshed walker submits the new residency successfully.
    const mesh_handle = try resident(&engine.assets, names[0]);
    const old_mesh = engine.assets.payloadOf(mesh_handle).?.asHandle(render3d.MeshHandle);
    const mesh_source = try sourceOf(&engine.store, names[0]);
    const mesh_bytes = try engine.os.readFileConfined(gpa, root, mesh_source, 1024 * 1024);
    defer gpa.free(mesh_bytes.bytes);
    try replace(&engine.assets, &engine.store, engine.os, root, names[0], mesh_bytes.bytes);
    try content.contentChanged();
    try walker.refresh(gpa, &engine.store, &first.world, &content, dt);
    try testing.expect(renderer.meshJointCount(old_mesh) == null);
    try renderer.begin(.{ .camera = .{}, .target_size = .{ .width = 64, .height = 64 } });
    try walker.draw(&content, .zero);
    // Malformed reload preserves the healthy candidate; a valid but incompatible clip
    // refuses pairing and disables this walker without retaining any dangling borrow.
    try testing.expectError(error.InvalidAsset, replace(&engine.assets, &engine.store, engine.os, root, names[2], "broken"));
    try walker.evaluate(&content, dt);
    const model_record = engine.store.lookup(core.ContentId.fromString("sandbox3d:models.walker")).?;
    const named = (try model_record.fields.listAt(model_record.schema.fieldIndex("clips").?)).?;
    for (0..2) |i| {
        const entry = (try named.nestedAt(@intCast(i))).?;
        const name = @constCast((try entry.stringAt(0)).?);
        const original_letter = name[0];
        name[0] = 'x';
        try content.contentChanged();
        const refused = walker.refresh(gpa, &engine.store, &first.world, &content, dt);
        name[0] = original_letter;
        try testing.expectError(if (i == 0) error.MissingIdle else error.MissingWalk, refused);
        try testing.expect(walker.character.isNone() and walker.joint_count == 0);
        try content.contentChanged();
        try walker.refresh(gpa, &engine.store, &first.world, &content, dt);
    }
    const mismatch = try asset.animation.write(gpa, .{ .duration = 1, .joint_count = 1, .tracks = &.{} });
    defer gpa.free(mismatch);
    try replace(&engine.assets, &engine.store, engine.os, root, names[2], mismatch);
    try testing.expectError(error.SkeletonMismatch, walker.refresh(gpa, &engine.store, &first.world, &content, dt));
    try testing.expect(walker.character.isNone() and walker.model.isNone() and walker.joint_count == 0);
    var empty: data.Store = .init(gpa, .default);
    defer empty.deinit(gpa);
    try testing.expectError(error.MissingWalker, walker.refresh(gpa, &empty, &first.world, &content, dt));
    try testing.expect(walker.character.isNone() and walker.model.isNone() and walker.joint_count == 0);
}

fn sourceOf(store: *const data.Store, name: []const u8) ![]const u8 {
    const record = store.lookup(core.ContentId.fromString(name)) orelse return error.MissingRecord;
    return (try record.fields.stringAt(record.schema.fieldIndex("source").?)) orelse return error.MissingSource;
}
fn replace(assets: *asset.Registry, store: *const data.Store, os: *platform.os.Os, root: []const u8, name: []const u8, bytes: []const u8) !void {
    const path = try platform.os.joinPath(testing.allocator, &.{ root, try sourceOf(store, name) });
    defer testing.allocator.free(path);
    try os.writeFile(path, bytes);
    try assets.reload(testing.allocator, try resident(assets, name));
}
fn resident(assets: *const asset.Registry, name: []const u8) !asset.AssetHandle {
    var entries = assets.assets();
    while (entries.next()) |entry| if (entry.id.eql(core.ContentId.fromString(name))) return entry.handle;
    return error.NotResident;
}

test "walker settings: bounded fields, waypoint cardinality and nonfinite values refuse" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const os = try platform.os.Os.init(gpa, .{});
    defer os.deinit();
    var schemas: data.Registry = .init(gpa, .default);
    defer schemas.deinit(gpa);
    try asset.schemas.registerAll(gpa, &schemas);
    var diagnostics: data.Diagnostics = .init(gpa, .default);
    defer diagnostics.deinit(gpa);
    var store: data.Store = .init(gpa, .default);
    defer store.deinit(gpa);
    const bytes = try os.readFile(gpa, options.package, 16 * 1024 * 1024);
    defer gpa.free(bytes);
    _ = try store.add(gpa, "sandbox3d:content", bytes, &schemas, &diagnostics);
    const fields = store.lookup(core.ContentId.fromString("sandbox3d:walker.main")).?.fields;
    const settings = try walker_mod.Settings.read(fields);
    try testing.expectEqual(@as(usize, 4), settings.len);
    const copied = try gpa.dupe(u8, fields.block);
    defer gpa.free(copied);
    var edited = fields;
    edited.block = copied;
    for (0..fields.fields.len) |i| {
        @memcpy(copied, fields.block);
        copied[i / 8] &= ~(@as(u8, 1) << @intCast(i % 8));
        try testing.expectError(error.InvalidWalker, walker_mod.Settings.read(edited));
    }
    // FPK aligns the model ID to eight bytes, then a list descriptor and two floats.
    for ([_]usize{ copied.len - 8, copied.len - 4 }) |offset| {
        for ([_]f32{ 0, -1, std.math.nan(f32), std.math.inf(f32), 100 }) |value| {
            @memcpy(copied, fields.block);
            std.mem.writeInt(u32, copied[offset..][0..4], @bitCast(value), .little);
            try testing.expectError(error.InvalidWalker, walker_mod.Settings.read(edited));
        }
    }
    for ([_]u32{ 0, 1, 17 }) |count| {
        @memcpy(copied, fields.block);
        std.mem.writeInt(u32, copied[copied.len - 12 ..][0..4], count, .little);
        try testing.expectError(error.InvalidWalker, walker_mod.Settings.read(edited));
    }
    @memcpy(copied, fields.block);
    // Zero model ID, nonfinite waypoint and identical neighbours each have a guard.
    @memset(copied[8..16], 0);
    try testing.expectError(error.InvalidWalker, walker_mod.Settings.read(edited));
    const points = (try fields.listAt(1)).?;
    const first_point = (try points.nestedAt(0)).?;
    const second_point = (try points.nestedAt(1)).?;
    const mutable = @constCast(first_point.block);
    const saved = try gpa.dupe(u8, mutable);
    defer gpa.free(saved);
    defer @memcpy(mutable, saved);
    std.mem.writeInt(u32, mutable[mutable.len - 12 ..][0..4], @bitCast(std.math.nan(f32)), .little);
    try testing.expectError(error.InvalidWalker, walker_mod.Settings.read(fields));
    @memcpy(mutable, second_point.block);
    try testing.expectError(error.InvalidWalker, walker_mod.Settings.read(fields));
}
