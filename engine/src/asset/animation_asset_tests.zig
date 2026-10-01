//! M24 Step 2's independent binary, ownership, limits and compatibility evidence.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const skeleton = @import("skeleton.zig");
const animation = @import("animation.zig");
const mesh = @import("mesh.zig");
const mesh_file = @import("mesh_file.zig");
const schemas = @import("schemas.zig");
const bin = @import("animation_binary.zig");
const t = std.testing;
const gpa = t.allocator;
const rests = [_]core.math.Transform{ .{}, .{ .translation = .init(0, 1, 0) } };
const binds = [_]core.math.Mat4{ .identity, core.math.Mat4.translation(.init(0, -1, 0)) };
const skel_source: skeleton.Source = .{ .parents = &.{ skeleton.no_parent, 0 }, .rest = &rests, .inverse_bind = &binds, .names = &.{ "root", "hand.R" } };
const tracks = [_]animation.Track{
    .{ .joint = 0, .path = .translation, .times = &.{ 0, 1 }, .values = &.{ 0, 0, 0, 1, 0, 0 } },
    .{ .joint = 1, .path = .rotation, .interpolation = .step, .times = &.{ 0, 1 }, .values = &.{ 0, 0, 0, 1, 0, 0, 1, 0 } },
};
const clip_source: animation.Source = .{ .duration = 1, .joint_count = 2, .tracks = &tracks };

test "fskel: canonical hash, unaligned borrowed round trip, aligned independent ownership" {
    const b = try skeleton.write(gpa, skel_source);
    defer gpa.free(b);
    try t.expectEqual(@as(u64, 6071047475770041445), core.id.fnv1a64(b));
    const unaligned = try gpa.alloc(u8, b.len + 1);
    defer gpa.free(unaligned);
    @memcpy(unaligned[1..], b);
    const v = try skeleton.read(unaligned[1..], .default);
    try t.expectEqualStrings("hand.R", v.name(1));
    try t.expectEqual(@as(u16, 0), v.parent(1));
    try t.expectEqualDeep(rests[1], v.rest(1));
    try t.expectEqualDeep(binds[1], v.inverseBind(1));
    var owned = try v.copy(gpa);
    defer owned.deinit(gpa);
    @memset(unaligned, 0);
    try t.expectEqualStrings("hand.R", owned.names[1]);
    try t.expectEqualDeep(rests[1], owned.rest[1]);
    const again = try skeleton.write(gpa, .{ .parents = owned.parents, .rest = owned.rest, .inverse_bind = owned.inverse_bind, .root = owned.root, .names = owned.names });
    defer gpa.free(again);
    try t.expectEqualSlices(u8, b, again);
}

test "fskel: every named read error, exact structure, names and bounded work" {
    const b = try skeleton.write(gpa, skel_source);
    defer gpa.free(b);
    const changed = try gpa.dupe(u8, b);
    defer gpa.free(changed);
    try t.expectError(error.NotASkeleton, skeleton.read("no", .default));
    const Case = struct { at: usize, value: u32, err: skeleton.ReadError };
    const cases = [_]Case{
        .{ .at = 4, .value = 2, .err = error.UnsupportedVersion },
        .{ .at = 8, .value = 0, .err = error.NoJoints },
        .{ .at = 8, .value = 257, .err = error.OverLimit },
        .{ .at = 12, .value = 65_537, .err = error.OverLimit },
        .{ .at = 16, .value = 0, .err = error.ParentOutOfOrder },
        .{ .at = 16, .value = 0x1ffff, .err = error.Malformed },
        .{ .at = 20, .value = @bitCast(std.math.nan(f32)), .err = error.InvalidRest },
        .{ .at = 44, .value = 0, .err = error.InvalidRest }, // quaternion w
        .{ .at = 60, .value = @bitCast(std.math.inf(f32)), .err = error.InvalidInverseBind },
        .{ .at = 72, .value = @bitCast(@as(f32, 1)), .err = error.InvalidInverseBind }, // affine row
        .{ .at = 232, .value = @bitCast(std.math.nan(f32)), .err = error.InvalidRoot },
        .{ .at = 244, .value = @bitCast(@as(f32, 1)), .err = error.InvalidRoot },
        .{ .at = 296, .value = 1, .err = error.Malformed }, // name offset
        .{ .at = 300, .value = std.math.maxInt(u32), .err = error.Malformed },
        .{ .at = 304, .value = 0, .err = error.Malformed }, // gap/overlap
    };
    for (cases) |c| {
        @memcpy(changed, b);
        bin.put(u32, changed, c.at, c.value);
        try t.expectError(c.err, skeleton.read(changed, .default));
    }
    @memcpy(changed, b);
    changed[312] = 0;
    try t.expectError(error.InvalidName, skeleton.read(changed, .default));
    @memcpy(changed, b);
    changed[312] = 0xff;
    try t.expectError(error.InvalidName, skeleton.read(changed, .default));
    try t.expectError(error.Malformed, skeleton.read(b[0..15], .default));
    try t.expectError(error.Malformed, skeleton.read(b[0 .. b.len - 1], .default));
    const extra = try std.mem.concat(gpa, u8, &.{ b, &.{0} });
    defer gpa.free(extra);
    try t.expectError(error.Malformed, skeleton.read(extra, .default));
    try t.expectError(error.OverLimit, skeleton.read(b, .{ .max_file_bytes = b.len - 1 }));
    try t.expectError(error.OverLimit, skeleton.read(b, .{ .max_joints = 1 }));
    try t.expectError(error.OverLimit, skeleton.read(b, .{ .max_name_bytes = 9 }));
}

test "fanim: canonical hash, unaligned borrowed round trip and aligned independent ownership" {
    const b = try animation.write(gpa, clip_source);
    defer gpa.free(b);
    try t.expectEqual(@as(u64, 9601173013537569255), core.id.fnv1a64(b));
    const unaligned = try gpa.alloc(u8, b.len + 1);
    defer gpa.free(unaligned);
    @memcpy(unaligned[1..], b);
    const v = try animation.read(unaligned[1..], .default);
    try t.expect(@intFromPtr(v.track(0).times.ptr) == @intFromPtr(unaligned.ptr) + 1 + 52);
    var owned = try v.copy(gpa);
    defer owned.deinit(gpa);
    @memset(unaligned, 0);
    try t.expectEqualSlices(f32, tracks[1].values, owned.tracks[1].values);
    try owned.checkJointCount(2);
    try t.expectError(error.SkeletonMismatch, owned.checkJointCount(1));
    const again = try animation.write(gpa, .{ .duration = owned.duration, .joint_count = owned.joint_count, .tracks = owned.tracks });
    defer gpa.free(again);
    try t.expectEqualSlices(u8, b, again);
    // A positive-duration clip may have no tracks: sampling keeps the rest pose.
    const empty = try animation.write(gpa, .{ .duration = 2, .joint_count = 2, .tracks = &.{} });
    defer gpa.free(empty);
    try t.expectEqual(@as(u32, 0), (try animation.read(empty, .default)).track_count);
}

test "fanim: every named read error, descriptors, values, limits and exact payload" {
    const b = try animation.write(gpa, clip_source);
    defer gpa.free(b);
    const changed = try gpa.dupe(u8, b);
    defer gpa.free(changed);
    try t.expectError(error.NotAnAnimation, animation.read("no", .default));
    const Case = struct { at: usize, value: u32, err: animation.ReadError };
    const cases = [_]Case{
        .{ .at = 4, .value = 2, .err = error.UnsupportedVersion },
        .{ .at = 8, .value = 0, .err = error.InvalidDuration },
        .{ .at = 8, .value = @bitCast(std.math.nan(f32)), .err = error.InvalidDuration },
        .{ .at = 12, .value = 0, .err = error.InvalidJointCount },
        .{ .at = 12, .value = 257, .err = error.OverLimit },
        .{ .at = 16, .value = 769, .err = error.OverLimit },
        .{ .at = 20, .value = 2 | (1 << 24), .err = error.UnknownJoint },
        .{ .at = 36, .value = (1 << 24), .err = error.DuplicateTrack },
        .{ .at = 24, .value = 0, .err = error.EmptyTrack },
        .{ .at = 24, .value = 65_537, .err = error.OverLimit },
        .{ .at = 28, .value = 56, .err = error.Malformed },
        .{ .at = 32, .value = 64, .err = error.Malformed },
        .{ .at = 52, .value = @bitCast(@as(f32, -1)), .err = error.InvalidTime },
        .{ .at = 52, .value = @bitCast(std.math.inf(f32)), .err = error.InvalidTime },
        .{ .at = 56, .value = 0, .err = error.UnsortedTimes },
        .{ .at = 56, .value = @bitCast(@as(f32, 2)), .err = error.InvalidTime },
        .{ .at = 60, .value = @bitCast(std.math.nan(f32)), .err = error.InvalidValue },
        .{ .at = 104, .value = 0, .err = error.InvalidRotation },
    };
    for (cases) |c| {
        @memcpy(changed, b);
        bin.put(u32, changed, c.at, c.value);
        try t.expectError(c.err, animation.read(changed, .default));
    }
    for ([_]usize{ 22, 23 }) |at| {
        @memcpy(changed, b);
        changed[at] = 9;
        try t.expectError(error.Malformed, animation.read(changed, .default));
    }
    try t.expectError(error.Malformed, animation.read(b[0..19], .default));
    try t.expectError(error.Malformed, animation.read(b[0 .. b.len - 1], .default));
    const extra = try std.mem.concat(gpa, u8, &.{ b, &.{0} });
    defer gpa.free(extra);
    try t.expectError(error.Malformed, animation.read(extra, .default));
    try t.expectError(error.OverLimit, animation.read(b, .{ .max_file_bytes = b.len - 1 }));
    try t.expectError(error.OverLimit, animation.read(b, .{ .max_tracks = 1 }));
    try t.expectError(error.OverLimit, animation.read(b, .{ .max_joints = 1 }));
    try t.expectError(error.OverLimit, animation.read(b, .{ .max_keys_per_track = 1 }));
    try t.expectError(error.OverLimit, animation.read(b, .{ .max_total_keys = 3 }));
}

const SkinFixture = struct {
    positions: [3]core.math.Vec3 = .{ .init(-1, 0, 0), .init(1, 0, 0), .init(0, 1, 0) },
    joints: [3][4]u8 = .{ .{ 0, 1, 255, 255 }, .{ 1, 0, 255, 255 }, .{ 0, 1, 255, 255 } },
    weights: [3][4]f32 = .{ .{ 0.5, 0.5, 0, 0 }, .{ 1, 0, 0, 0 }, .{ 0.5, 0.5, 0, 0 } },
    indices: [3]u16 = .{ 0, 1, 2 },
    submeshes: [1]mesh.Submesh = .{.{ .first_index = 0, .index_count = 3 }},
    bounds: [2]mesh.Aabb = .{ .{ .min = .init(-1, 0, 0), .max = .init(1, 1, 0) }, .{ .min = .init(-1, 0, 0), .max = .init(1, 1, 0) } },
    streams: [3]mesh.Stream = undefined,
    fn value(f: *SkinFixture) mesh.Mesh {
        f.streams = .{ .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&f.positions) }, .{ .semantic = .joints, .format = .uint8x4, .bytes = std.mem.sliceAsBytes(&f.joints) }, .{ .semantic = .weights, .format = .float32x4, .bytes = std.mem.sliceAsBytes(&f.weights) } };
        return .{ .vertex_count = 3, .streams = &f.streams, .index_format = .uint16, .indices = std.mem.sliceAsBytes(&f.indices), .submeshes = &f.submeshes, .bounds = f.bounds[0], .joint_bounds = &f.bounds };
    }
};
test "fmesh v2: pinned round trip, unaligned bounds and unchanged v1 bytes" {
    var fixture: SkinFixture = .{};
    const b = try mesh_file.write(gpa, fixture.value());
    defer gpa.free(b);
    try t.expectEqual(@as(u64, 14238423240801818177), core.id.fnv1a64(b));
    try t.expectEqual(@as(?u32, 2), mesh_file.versionOf(b));
    const unaligned = try gpa.alloc(u8, b.len + 1);
    defer gpa.free(unaligned);
    @memcpy(unaligned[1..], b);
    var v = try mesh_file.read(unaligned[1..], .default);
    const again = try mesh_file.write(gpa, v.mesh());
    defer gpa.free(again);
    try t.expectEqualSlices(u8, b, again);
    var plain = fixture.value();
    plain.streams = plain.streams[0..1];
    plain.joint_bounds = &.{};
    const old = try mesh_file.write(gpa, plain);
    defer gpa.free(old);
    try t.expectEqual(@as(?u32, 1), mesh_file.versionOf(old));
    // Also calculated independently from M20's 48-byte header/table/payload specification.
    try t.expectEqual(@as(u64, 2781668076031273099), core.id.fnv1a64(old));
    var old_view = try mesh_file.read(old, .default);
    try t.expectEqual(@as(usize, 0), old_view.mesh().joint_bounds.len);
    const old_again = try mesh_file.write(gpa, old_view.mesh());
    defer gpa.free(old_again);
    try t.expectEqualSlices(u8, old, old_again);
}

test "fmesh v2: skin streams, influences and conservative boxes are all-or-nothing" {
    var fixture: SkinFixture = .{};
    var value = fixture.value();
    try value.validate();
    value.streams = value.streams[0..2];
    try t.expectError(error.IncompleteSkin, value.validate());
    value = fixture.value();
    value.joint_bounds = &.{};
    try t.expectError(error.IncompleteSkin, value.validate());
    value = fixture.value();
    fixture.streams[1].format = .unorm8x4;
    try t.expectError(error.UnsupportedVertexFormat, value.validate());
    value = fixture.value();
    fixture.joints[0][0] = 2;
    try t.expectError(error.JointOutOfRange, value.validate());
    fixture.joints[0][0] = 0;
    for ([_]f32{ -1, 0, std.math.nan(f32), std.math.inf(f32), 0.6 }) |bad| {
        fixture.weights[0][0] = bad;
        try t.expectError(error.InvalidWeights, value.validate());
    }
    fixture.weights[0][0] = 0.5;
    fixture.bounds[0].max.y = 0;
    try t.expectError(error.InvalidJointBounds, value.validate());
    fixture.bounds[0].max.y = 1;
    fixture.bounds[0].min.x = std.math.nan(f32);
    try t.expectError(error.InvalidJointBounds, value.validate());
    fixture.bounds[0].min.x = -1;
    const large = [_]mesh.Aabb{fixture.bounds[0]} ** 257;
    value.joint_bounds = &large;
    try t.expectError(error.TooManyJoints, value.validate());
    value = fixture.value();
    const b = try mesh_file.write(gpa, value);
    defer gpa.free(b);
    const changed = try gpa.dupe(u8, b);
    defer gpa.free(changed);
    for ([_]usize{ 50, 52 }) |at| {
        @memcpy(changed, b);
        changed[at] = 1;
        try t.expectError(error.Malformed, mesh_file.read(changed, .default));
    }
    @memcpy(changed, b);
    bin.put(u16, changed, 48, 0);
    try t.expectError(error.Malformed, mesh_file.read(changed, .default));
    @memcpy(changed, b);
    bin.put(u16, changed, 48, 257);
    try t.expectError(error.OverLimit, mesh_file.read(changed, .default));
    try t.expectError(error.OverLimit, mesh_file.read(b, .{ .max_joints = 1 }));
    try t.expectError(error.Malformed, mesh_file.read(b[0 .. b.len - 1], .default));
}

fn copies(g: std.mem.Allocator) !void {
    const sb = try skeleton.write(g, skel_source);
    defer g.free(sb);
    var sk = try (try skeleton.read(sb, .default)).copy(g);
    defer sk.deinit(g);
    const ab = try animation.write(g, clip_source);
    defer g.free(ab);
    var a = try (try animation.read(ab, .default)).copy(g);
    defer a.deinit(g);
    const sl = skeleton.skeletonLoader();
    const sp = try sl.load(sl.ctx, g, undefined, sb);
    defer sl.unload(sl.ctx, g, sp);
    const al = animation.animationLoader();
    const ap = try al.load(al.ctx, g, undefined, ab);
    defer al.unload(al.ctx, g, ap);
}
test "animation assets: every allocation failure releases partial owned copies" {
    try t.checkAllAllocationFailures(gpa, copies, .{});
}

test "animation asset loaders: source lifetime, unload and version refusals" {
    const loaders = .{ skeleton.skeletonLoader(), animation.animationLoader() };
    const sb = try skeleton.write(gpa, skel_source);
    defer gpa.free(sb);
    const ab = try animation.write(gpa, clip_source);
    defer gpa.free(ab);
    inline for (loaders, 0..) |loader, i| {
        const source = try gpa.dupe(u8, if (i == 0) sb else ab);
        defer gpa.free(source);
        const payload = try loader.load(loader.ctx, gpa, undefined, source);
        defer loader.unload(loader.ctx, gpa, payload);
        @memset(source, 0);
        if (i == 0) try t.expectEqualStrings("hand.R", skeleton.fromPayload(payload).names[1]) else try t.expectEqualSlices(f32, tracks[0].values, animation.fromPayload(payload).tracks[0].values);
        @memcpy(source, if (i == 0) sb else ab);
        bin.put(u32, source, 4, 2);
        try t.expectError(error.UnsupportedVersion, loader.load(loader.ctx, gpa, undefined, source));
        try t.expectError(error.InvalidAsset, loader.load(loader.ctx, gpa, undefined, "bad"));
    }
}

test "animation formats: writers refuse mismatched values before exposing a file" {
    var s = skel_source;
    s.names = &.{};
    try t.expectError(error.LengthMismatch, skeleton.write(gpa, s));
    s = skel_source;
    s.root.cols[0][3] = 1;
    try t.expectError(error.InvalidRoot, skeleton.write(gpa, s));
    var track = tracks[0];
    track.values = &.{0};
    try t.expectError(error.ValueCountMismatch, animation.write(gpa, .{ .duration = 1, .joint_count = 2, .tracks = &.{track} }));
    try t.expectError(error.InvalidDuration, animation.write(gpa, .{ .duration = 0, .joint_count = 2, .tracks = &.{} }));
}

test "model v2: a compiled version 1 model still reads slots and parts with optional skin absent" {
    var registry = data.Registry.init(gpa, .default);
    defer registry.deinit(gpa);
    const old: data.Schema = .{ .id = schemas.model.id, .version = 1, .fields = schemas.model.fields[0..2] };
    _ = try registry.register(gpa, old);
    var package = try data.Package.init(gpa, "test:content", 1, .default);
    defer package.deinit(gpa);
    var diags = data.Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);
    var doc = try data.parser.parse(gpa, "old.fdt", "foundry:model test:old { slots [] parts [] }", .{ .namespace = "test" }, &diags);
    defer doc.deinit(gpa);
    try package.addDocument(gpa, &doc, &registry, &diags);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try data.fpk.write(gpa, &package, &registry, &bytes);
    _ = try registry.register(gpa, schemas.model);
    var store = data.Store.init(gpa, .default);
    defer store.deinit(gpa);
    _ = try store.add(gpa, "old.fpk", bytes.items, &registry, &diags);
    const record = store.lookup(core.ContentId.fromString("test:old")).?;
    try t.expectEqual(@as(u32, 1), record.schema.version);
    try t.expectEqual(@as(u32, 0), (try record.fields.listAt(0)).?.len);
    try t.expectEqual(@as(u32, 0), (try record.fields.listAt(1)).?.len);
    try t.expect((try record.fields.idAt(2)) == null);
    try t.expect((try record.fields.listAt(3)) == null);
    try t.expect(schemas.model.fields[2].presence == .optional);
    try t.expect(schemas.model.fields[3].presence == .optional);
}

test "animation assets: maximum joint count and empty names round trip without narrowing 256" {
    const parents = [_]u16{skeleton.no_parent} ** 256;
    const rest_values = [_]core.math.Transform{.{}} ** 256;
    const inverse = [_]core.math.Mat4{.identity} ** 256;
    const names = [_][]const u8{""} ** 256;
    const sb = try skeleton.write(gpa, .{ .parents = &parents, .rest = &rest_values, .inverse_bind = &inverse, .names = &names });
    defer gpa.free(sb);
    try t.expectEqual(@as(u32, 256), (try skeleton.read(sb, .default)).joint_count);
    const ab = try animation.write(gpa, .{ .duration = 1, .joint_count = 256, .tracks = &.{.{ .joint = 255, .path = .scale, .times = &.{0}, .values = &.{ 1, 1, 1 } }} });
    defer gpa.free(ab);
    try t.expectEqual(@as(u16, 255), (try animation.read(ab, .default)).track(0).joint);
}
