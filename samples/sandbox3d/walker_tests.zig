//! Compiled package -> renderer/model handles -> patrol -> poses, reload and replay.
const std = @import("std");
const builtin = @import("builtin");
const app = @import("app");
const anim = @import("anim");
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
    var rigs = asset.Rigs.init(gpa, &engine.assets);
    defer rigs.deinit();
    var first = Walk.init(gpa);
    defer first.deinit(&engine.assets);
    first.refresh(&engine.store, &engine.assets, dt);
    var walker: Walker = .{};
    defer walker.deinit(gpa, &first.world, &content, &rigs);
    try walker.refresh(gpa, &engine.store, &first.world, &content, &rigs);
    try testing.expectEqual(@as(usize, 19), walker.joint_count);
    try testing.expect(walker.player.playing(anim.clipName("idle")));
    var tour: Tour = .{ .emit = false };
    var second = Walk.init(gpa);
    defer second.deinit(&engine.assets);
    second.refresh(&engine.store, &engine.assets, dt);
    var replay: Walker = .{};
    defer replay.deinit(gpa, &second.world, &content, &rigs);
    try replay.refresh(gpa, &engine.store, &second.world, &content, &rigs);
    var m24: M24 = try .init(&content, walker.model);
    for (0..Walker.proof_ticks) |_| {
        if (!tour.done()) try tour.advance(&first, dt);
        try walker.move(gpa, &first.world, &rigs, dt);
        try walker.evaluate(&rigs);
        walker.record();
        try replay.move(gpa, &second.world, &rigs, dt);
        try replay.evaluate(&rigs);
        replay.record();
        try m24.check(&walker);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(walker.pose[0..walker.joint_count]), std.mem.sliceAsBytes(replay.pose[0..replay.joint_count]));
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(walker.matrices[0..walker.joint_count]), std.mem.sliceAsBytes(replay.matrices[0..replay.joint_count]));
        try testing.expectEqual(walker.hash, replay.hash);
    }
    try testing.expect(walker.proofPassed() and replay.proofPassed());
    try testing.expect(tour.failed == null and tour.done());
    try testing.expectEqual(@as(u64, 0xcb99ccfcf2b6d6c3), tour.hash);
    // Same-binary replay above is exact. These are the two math-provider pins (animation3d.md
    // Step 6), moved once by M34, when time went from `f32` to `f64` within the tolerance `M24`
    // proves. Linking v6 also pulls compiler-runtime sin into an optimized host, so optimization
    // mode alone no longer identifies its provider.
    if (builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos)
        try testing.expect(walker.hash == 0x655e865f98779129);
    const feet = walker.feet;
    const tick = walker.tick;
    const old_character = walker.character;
    try walker.refresh(gpa, &engine.store, &first.world, &content, &rigs);
    try testing.expectEqualDeep(feet, walker.feet);
    try testing.expectEqual(tick, walker.tick);
    try testing.expect(first.world.character(old_character) == null);
    // A changed patrol record restarts playback/proof, unlike an unchanged asset refresh.
    const patrol = engine.store.lookup(core.ContentId.fromString("sandbox3d:walker.main")).?;
    const editable = @constCast(patrol.fields.block);
    const speed_offset = editable.len - 8;
    const saved_speed: [4]u8 = editable[speed_offset..][0..4].*;
    std.mem.writeInt(u32, editable[speed_offset..][0..4], @bitCast(@as(f32, 0.7)), .little);
    try walker.refresh(gpa, &engine.store, &first.world, &content, &rigs);
    try testing.expectEqual(@as(u64, 0), walker.tick);
    try testing.expectEqual(@as(u32, 0), walker.reached);
    try testing.expect(!walker.used_walk and !walker.used_fade);
    try testing.expectEqual(@as(u64, 0xcbf29ce484222325), walker.hash);
    try testing.expectEqual(@as(f32, 0), walker.player.seconds(rigs.get(walker.rig).?.*, walker.player.newest));
    @memcpy(editable[speed_offset..][0..4], &saved_speed);
    try walker.refresh(gpa, &engine.store, &first.world, &content, &rigs);
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
    try rigs.contentChanged();
    try walker.refresh(gpa, &engine.store, &first.world, &content, &rigs);
    try testing.expect(!std.meta.eql(before_matrix, walker.matrices[0]));
    const clip_bytes = try asset.animation.write(gpa, .{ .duration = 1, .joint_count = @intCast(walker.joint_count), .tracks = &.{.{ .joint = 1, .path = .rotation, .times = &.{ 0, 1 }, .values = &.{ 0.09983342, 0, 0, 0.9950042, 0.09983342, 0, 0, 0.9950042 } }} });
    defer gpa.free(clip_bytes);
    const before_pose = walker.pose[1];
    try replace(&engine.assets, &engine.store, engine.os, root, names[2], clip_bytes);
    try rigs.contentChanged();
    try walker.refresh(gpa, &engine.store, &first.world, &content, &rigs);
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
    try rigs.contentChanged();
    try walker.refresh(gpa, &engine.store, &first.world, &content, &rigs);
    try testing.expect(renderer.meshJointCount(old_mesh) == null);
    try renderer.begin(.{ .camera = .{}, .target_size = .{ .width = 64, .height = 64 } });
    try walker.draw(&content, .zero);
    // Malformed reload preserves the healthy candidate; a valid but incompatible clip
    // refuses pairing and disables this walker without retaining any dangling borrow.
    try testing.expectError(error.InvalidAsset, replace(&engine.assets, &engine.store, engine.os, root, names[2], "broken"));
    try walker.evaluate(&rigs);
    const model_record = engine.store.lookup(core.ContentId.fromString("sandbox3d:models.walker")).?;
    const named = (try model_record.fields.listAt(model_record.schema.fieldIndex("clips").?)).?;
    for (0..2) |i| {
        const entry = (try named.nestedAt(@intCast(i))).?;
        const name = @constCast((try entry.stringAt(0)).?);
        const original_letter = name[0];
        name[0] = 'x';
        try content.contentChanged();
        try rigs.contentChanged();
        const refused = walker.refresh(gpa, &engine.store, &first.world, &content, &rigs);
        name[0] = original_letter;
        // A package keeps one copy of a string, so this renames the set's `start` too, and the rig
        // still builds: what's missing is the clip the walker asks for.
        try testing.expectError(if (i == 0) error.MissingIdle else error.MissingWalk, refused);
        try testing.expect(walker.character.isNone() and walker.joint_count == 0);
        try content.contentChanged();
        try rigs.contentChanged();
        try walker.refresh(gpa, &engine.store, &first.world, &content, &rigs);
    }
    const mismatch = try asset.animation.write(gpa, .{ .duration = 1, .joint_count = 1, .tracks = &.{} });
    defer gpa.free(mismatch);
    try replace(&engine.assets, &engine.store, engine.os, root, names[2], mismatch);
    try rigs.contentChanged();
    try testing.expectError(error.MissingRig, walker.evaluate(&rigs));
    try testing.expectEqual(@as(usize, 0), walker.joint_count);
    try testing.expectError(error.MissingRig, walker.move(gpa, &first.world, &rigs, dt));
    try testing.expectError(error.JointCountMismatch, walker.refresh(gpa, &engine.store, &first.world, &content, &rigs));
    try testing.expect(walker.character.isNone() and walker.model.isNone() and walker.joint_count == 0);
    var empty: data.Store = .init(gpa, .default);
    defer empty.deinit(gpa);
    try testing.expectError(error.MissingWalker, walker.refresh(gpa, &empty, &first.world, &content, &rigs));
    try testing.expect(walker.character.isNone() and walker.model.isNone() and walker.rig.isNone() and walker.joint_count == 0);
}

/// The walker as M24 played it: both clips at `tick × dt` in `f32`, a weight added to tick by tick
/// and one blend. M34 keeps it here as the reference a change of arithmetic has to stay close to.
const M24 = struct {
    skeleton: anim.Skeleton,
    idle: *const asset.animation.Animation,
    walk: *const asset.animation.Animation,
    weight: f32 = 0,
    worst: f32 = 0,
    idle_pose: [256]core.math.Transform = undefined,
    walk_pose: [256]core.math.Transform = undefined,
    pose: [256]core.math.Transform = undefined,
    idle_tracks: [anim.clip.max_tracks]anim.Track = undefined,
    walk_tracks: [anim.clip.max_tracks]anim.Track = undefined,

    const tolerance = 1e-4;

    fn init(content: *render3d.Content, model: render3d.ModelHandle) !M24 {
        const source = content.skeletonOf(model) orelse return error.MissingSkeleton;
        return .{
            .skeleton = .{ .parents = source.parents, .rest = source.rest, .inverse_bind = source.inverse_bind, .root = source.root },
            .idle = content.clipOf(model, "idle") orelse return error.MissingIdle,
            .walk = content.clipOf(model, "walk") orelse return error.MissingWalk,
        };
    }

    fn check(self: *M24, walker: *const Walker) !void {
        const n = walker.joint_count;
        const by = dt / walker.settings.?.cross_fade;
        const walking = walker.player.playing(anim.clipName("walk"));
        self.weight = std.math.clamp(self.weight + (if (walking) by else -by), 0, 1);
        const a = try clip(self.idle, n, &self.idle_tracks);
        const b = try clip(self.walk, n, &self.walk_tracks);
        const time = @as(f32, @floatFromInt(walker.tick)) * dt;
        const pose_a: anim.Pose = .{ .local = self.idle_pose[0..n] };
        const pose_b: anim.Pose = .{ .local = self.walk_pose[0..n] };
        const pose: anim.Pose = .{ .local = self.pose[0..n] };
        anim.sample(self.skeleton, a, anim.wrap(time, a.duration), pose_a);
        anim.sample(self.skeleton, b, anim.wrap(time, b.duration), pose_b);
        anim.blend(pose_a, pose_b, self.weight, pose);
        try self.near(walker.walkWeight(), self.weight);
        for (self.pose[0..n], walker.pose[0..n]) |then, now| {
            try self.near(then.translation.x, now.translation.x);
            try self.near(then.translation.y, now.translation.y);
            try self.near(then.translation.z, now.translation.z);
            try self.near(then.rotation.x, now.rotation.x);
            try self.near(then.rotation.y, now.rotation.y);
            try self.near(then.rotation.z, now.rotation.z);
            try self.near(then.rotation.w, now.rotation.w);
            try self.near(then.scale.x, now.scale.x);
            try self.near(then.scale.y, now.scale.y);
            try self.near(then.scale.z, now.scale.z);
        }
    }

    fn near(self: *M24, a: f32, b: f32) !void {
        self.worst = @max(self.worst, @abs(a - b));
        try testing.expect(@abs(a - b) <= tolerance);
    }
};

fn clip(source: *const asset.animation.Animation, count: usize, tracks: []anim.Track) !anim.Clip {
    try source.checkJointCount(count);
    for (source.tracks, tracks[0..source.tracks.len]) |from, *to| to.* = .{
        .joint = from.joint,
        .path = @enumFromInt(@intFromEnum(from.path)),
        .interpolation = @enumFromInt(@intFromEnum(from.interpolation)),
        .times = from.times,
        .values = from.values,
    };
    return .{ .duration = source.duration, .tracks = tracks[0..source.tracks.len] };
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

test "walker: M34's, M35's and M36's clips are appended, and old bytes stay" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const os = try platform.os.Os.init(gpa, .{});
    defer os.deinit();
    // What every clip before M35's, the mesh and the skeleton compile to, from before M35 appended its
    // four (`animation-states.md` §12). The walker and the warden share them, and both models have
    // M35's four after them. Only the walker has M36's eight walks after those (`animation-ik.md`
    // §11), and every earlier file kept its bytes when they came.
    for ([_][]const u8{ "clip0.fanim", "clip1.fanim", "clip2.fanim", "clip3.fanim", "clip4.fanim", "clip5.fanim", "clip6.fanim", "mesh0.fmesh", "skeleton0.fskel", "clip7.fanim", "clip8.fanim", "clip9.fanim", "clip10.fanim", "clip11.fanim", "clip12.fanim", "clip13.fanim", "clip14.fanim", "clip15.fanim", "clip16.fanim", "clip17.fanim", "clip18.fanim" }, [_]u64{ 0x1f2fa1d2d86042df, 0x5f966564dd9529be, 0x677f6e68ba41d452, 0xd6ea268c1b779558, 0x713aa9b4e2b9b0de, 0xa6f9a2d5f8bffd30, 0x84900a520fa63575, 0xeeef08a437cd77d7, 0xbb4e02a8a82029cb, 0x142f09c2287a2525, 0xdc62c95899a438d9, 0x39e40914d0fd57e7, 0x43a9fdfc1d1ae389, 0x122c4da5a46dabb3, 0x34b0f64bca2b9a83, 0xef89a05c4fa3eb03, 0xb0686e61ef271203, 0x827aeb25f7974f33, 0xe03dee8b0681ea83, 0x8a4267492bcb1e83, 0x9f99ecd1477cf203 }) |name, pin| {
        const path = try std.fs.path.join(gpa, &.{ options.generated, "models/walker", name });
        defer gpa.free(path);
        const bytes = try os.readFile(gpa, path, 1024 * 1024);
        defer gpa.free(bytes);
        try testing.expectEqual(pin, std.hash.Fnv1a_64.hash(bytes));
    }
}

test "walker: a stride covers its 0.6 m a second, and a turn is a quarter to the left" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const engine = try app.Engine.init(gpa, .{ .headless = true, .workers = 0, .content_dir = options.generated, .content = &.{
        .{ .base_dir = std.fs.path.dirname(options.core_package).?, .file = std.fs.path.basename(options.core_package), .root = "core-assets" },
        .{ .base_dir = std.fs.path.dirname(options.package).?, .file = std.fs.path.basename(options.package), .root = "sandbox3d-assets" },
    } });
    defer engine.deinit();
    var rigs = asset.Rigs.init(gpa, &engine.assets);
    defer rigs.deinit();
    const handle = try rigs.acquire(core.ContentId.fromString("sandbox3d:walker.set"));
    defer rigs.release(handle);
    const rig = rigs.get(handle).?;
    // Every clip as if it moved, to read what each carries.
    var clips: [anim.max_rig_clips]anim.RigClip = undefined;
    const count = rig.clips.len;
    @memcpy(clips[0..count], rig.clips);
    for (clips[0..count]) |*entry| entry.motion = true;
    var moving = rig.*;
    moving.clips = clips[0..count];
    moving.motion_joint = 0;
    try testing.expectApproxEqAbs(@as(f32, 0.6), moving.motionSpeed(anim.clipName("stride")), 1e-5);
    const turn = moving.find(anim.clipName("turn")).?;
    const turned = anim.motion.travel(moving, turn, 0, turn.clip.duration);
    try testing.expectApproxEqAbs(std.math.pi / 2.0, turned.yaw, 1e-5);
    for ([_][]const u8{ "jump", "drop" }) |name| {
        const entry = moving.find(anim.clipName(name)).?;
        const moved = anim.motion.travel(moving, entry, 0, entry.clip.duration);
        try testing.expectEqual(@as(f32, 0), moved.yaw);
        try testing.expectEqual(@as(f32, 0), moved.translation.length());
    }
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
    // FPK aligns the two IDs to eight bytes, then a list descriptor and two floats.
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
    @memcpy(copied, fields.block);
    @memset(copied[16..24], 0);
    try testing.expectError(error.InvalidWalker, walker_mod.Settings.read(edited));
    const points = (try fields.listAt(2)).?;
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

test "walker: M35's clips build a version 2 rig: a run in step with the stride, an upper mask, two additive clips and a climb's rise" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const engine = try app.Engine.init(gpa, .{ .headless = true, .workers = 0, .content_dir = options.generated, .content = &.{
        .{ .base_dir = std.fs.path.dirname(options.core_package).?, .file = std.fs.path.basename(options.core_package), .root = "core-assets" },
        .{ .base_dir = std.fs.path.dirname(options.package).?, .file = std.fs.path.basename(options.package), .root = "sandbox3d-assets" },
    } });
    defer engine.deinit();
    var rigs = asset.Rigs.init(gpa, &engine.assets);
    defer rigs.deinit();
    const handle = try rigs.acquire(core.ContentId.fromString("sandbox3d:walker.set"));
    defer rigs.release(handle);
    const rig = rigs.get(handle).?;
    // M35's eleven, and M36's eight walks and two blends (`animation-ik.md` §11).
    try testing.expectEqual(@as(usize, 21), rig.clips.len);

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

const walks = [_]struct { []const u8, f32, f32 }{
    .{ "walk.n", 0, 1 },  .{ "walk.ne", 1, 1 },   .{ "walk.e", 1, 0 },  .{ "walk.se", 1, -1 },
    .{ "walk.s", 0, -1 }, .{ "walk.sw", -1, -1 }, .{ "walk.w", -1, 0 }, .{ "walk.nw", -1, 1 },
};

test "walker: M36's lists build a version 3 rig: two legs, a gaze, `move`, and `walk8`, whose travel is its place" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const engine = try app.Engine.init(gpa, .{ .headless = true, .workers = 0, .content_dir = options.generated, .content = &.{
        .{ .base_dir = std.fs.path.dirname(options.core_package).?, .file = std.fs.path.basename(options.core_package), .root = "core-assets" },
        .{ .base_dir = std.fs.path.dirname(options.package).?, .file = std.fs.path.basename(options.package), .root = "sandbox3d-assets" },
    } });
    defer engine.deinit();
    var rigs = asset.Rigs.init(gpa, &engine.assets);
    defer rigs.deinit();
    const handle = try rigs.acquire(core.ContentId.fromString("sandbox3d:walker.set"));
    defer rigs.release(handle);
    const rig = rigs.get(handle).?;

    // The legs, their soles the feet's 8 cm at rest.
    try testing.expectEqual(@as(usize, 2), rig.legs.len);
    try testing.expectEqualStrings("left", rig.legs[0].label);
    try testing.expectEqual(anim.TwoBone{ .root = 13, .middle = 14, .end = 15 }, rig.legs[0].chain);
    try testing.expectEqual(anim.TwoBone{ .root = 16, .middle = 17, .end = 18 }, rig.legs[1].chain);
    for (rig.legs) |leg| try testing.expectApproxEqAbs(@as(f32, 0.08), leg.sole, 1e-6);
    // The gaze, over the neck and the head.
    try testing.expectEqual(@as(usize, 1), rig.aims.len);
    try testing.expectEqualStrings("head", rig.aims[0].label);
    try testing.expectEqual(@as(u16, 3), rig.aims[0].chain.joints[0].joint);
    try testing.expectEqual(@as(u16, 4), rig.aims[0].chain.joints[1].joint);

    // Standing, both feet are down all lap; walking, each foot is down for part of it.
    const idle = rig.find(anim.clipName("idle")).?;
    try testing.expectEqual(@as(usize, 2), idle.contacts.len);
    for (idle.contacts) |contact| try testing.expect(contact.from == 0 and contact.to == 1);
    var names: [walks.len + 1][]const u8 = undefined;
    names[0] = "stride";
    for (walks, 1..) |walk, i| names[i] = walk[0];
    for (names) |name| {
        const entry = rig.find(anim.clipName(name)).?;
        var legs = [_]bool{ false, false };
        for (entry.contacts) |contact| {
            legs[contact.leg] = true;
            try testing.expect(contact.from != 0 or contact.to != 1);
        }
        try testing.expect(legs[0] and legs[1]);
    }

    // Each walk travels its place on the grid in a one-second lap, in step with the stride.
    for (walks) |walk| {
        const entry = rig.find(anim.clipName(walk[0])).?;
        try testing.expect(entry.motion and entry.loop);
        try testing.expectEqual(@as(f32, 1), entry.clip.duration);
        try testing.expectEqual(anim.clipName("feet"), entry.sync);
        try testing.expectEqual(@as(usize, 2), entry.events.len);
        const moved = anim.motion.travel(rig.*, entry, 0, 1);
        try testing.expectApproxEqAbs(walk[1], moved.translation.x, 1e-5);
        try testing.expectApproxEqAbs(-walk[2], moved.translation.z, 1e-5);
    }

    // `move` is the walk and the run over speed, in the feet's group.
    const move = rig.find(anim.clipName("move")).?;
    try testing.expectEqual(anim.clipName("feet"), move.sync);
    try testing.expectEqual(@as(u8, 1), move.blend.?.axes());
    try testing.expect(move.motion);

    // `walk8` is a full 3 x 3 grid, and anywhere on it a lap travels its position.
    const walk8 = rig.find(anim.clipName("walk8")).?;
    try testing.expectEqual(@as(u8, 2), walk8.blend.?.axes());
    for ([_][2]f32{ .{ 0.3, -0.7 }, .{ 0.9, 0.2 }, .{ -0.5, 0.5 }, .{ -0.64, -0.64 }, .{ 0, 0.9 } }) |at| {
        const moved = anim.blend_space.travel(rig.*, walk8, at, 0, 1);
        try testing.expectApproxEqAbs(at[0], moved.translation.x, 1e-4);
        try testing.expectApproxEqAbs(-at[1], moved.translation.z, 1e-4);
        try testing.expectApproxEqAbs(@as(f64, 1), anim.blend_space.lapLength(rig.*, walk8, at), 1e-6);
    }
}
