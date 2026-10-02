const std = @import("std");
const abi = @import("abi");
const app = @import("app");
const asset = @import("asset");
const core = @import("core");
const data = @import("data");
const mod = @import("mod");
const platform = @import("platform");
const render3d = @import("render3d");
const native_mod = @import("native.zig");
const Native = native_mod.Native;
const Consent = native_mod.Consent;
const Orrery = @import("orrery.zig").Orrery;
const Walk = @import("walk.zig").Walk;
const Tour = @import("tour.zig").Tour;
const options = @import("walk_test_options");
const testing = std.testing;

test "native3d: consent is bounded, per package, deduplicated and refuses malformed input whole" {
    try testing.expectEqual(@as(usize, 0), (try Consent.parse(null)).len);
    const granted = try Consent.parse(" orbiter:content, ,orbiter:content,plinth:content ");
    try testing.expectEqual(@as(usize, 2), granted.len);
    try testing.expect(granted.contains(Native.orbiter_id));
    try testing.expect(!granted.contains(.fromString("other:content")));
    try testing.expectError(error.InvalidConsent, Consent.parse("orbiter:content,../bad"));
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..65) |i| {
        var buf: [64]u8 = undefined;
        try text.appendSlice(testing.allocator, try std.fmt.bufPrint(&buf, "extra:p{d},", .{i}));
    }
    try testing.expectError(error.TooManyConsents, Consent.parse(text.items));
}

fn proof(consented: bool) !u64 {
    const gpa = testing.allocator;
    const engine = try app.Engine.init(gpa, .{ .headless = true, .workers = 0, .content_dir = options.generated, .content = &.{
        .{ .base_dir = std.fs.path.dirname(options.core_package).?, .file = std.fs.path.basename(options.core_package), .root = "core-assets" },
        .{ .base_dir = std.fs.path.dirname(options.package).?, .file = std.fs.path.basename(options.package), .root = "sandbox3d-assets" },
        .{ .base_dir = std.fs.path.dirname(options.orbiter_package).?, .file = std.fs.path.basename(options.orbiter_package), .root = "orbiter-assets" },
    } });
    defer engine.deinit();
    // Mount generated fixtures exactly as install does, under the loaded package handles.
    try engine.assets.mount(gpa, engine.store.findPackage(Native.orbiter_id).?, options.orbiter_generated);
    try engine.assets.registerLoader(gpa, asset.collisionMeshLoader());
    var renderer = try render3d.Renderer.init(gpa, engine.gpu, .{ .cull = false });
    defer renderer.deinit();
    var content = render3d.Content.init(gpa, &renderer, &engine.assets, .default);
    defer content.deinit();
    var walk = Walk.init(gpa);
    defer walk.deinit(&engine.assets);
    const dt = engine.step_delta.toSecondsF32();
    walk.refresh(&engine.store, &engine.assets, dt);
    var orrery: Orrery = undefined;
    try orrery.init(gpa, engine.jobs());
    defer orrery.deinit();
    orrery.populate(&engine.store);
    var native: Native = undefined;
    try native.init(engine, &orrery.world, &content, &walk.world);
    var live = true;
    defer if (live) native.deinit();
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    const root = try scratch.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    try scratch.dir.createDir(std.testing.io, "orbiter", .default_dir);
    const name = try abi.libraryFileNameAlloc(gpa, "orbiter");
    defer gpa.free(name);
    const destination = try platform.os.joinPath(gpa, &.{ root, "orbiter", name });
    defer gpa.free(destination);
    const library = try engine.os.readFile(gpa, options.orbiter_library, 16 * 1024 * 1024);
    defer gpa.free(library);
    try engine.os.writeFile(destination, library);
    const entry: mod.Entry = .{ .id = Native.orbiter_id, .name = "orbiter:content", .base_dir = root, .file = "orbiter.fpk", .root = "orbiter", .version = 1, .abi = .{ .min = 6, .max = 6 }, .native = "orbiter" };
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    const consent = try Consent.parse(if (consented) "orbiter:content" else null);
    // Consent alone is never selection. No entry supplied means no library opened.
    try native.load(&.{}, consent, &diags);
    try testing.expect(native.canLoadWorld());
    try testing.expectEqual(@as(usize, 0), native.loader.loaded.items.len);
    const baseline_entities = orrery.world.entityCount();
    const baseline_bodies = walk.world.bodies.count();
    const baseline_systems = orrery.world.systemCount();
    try native.load(&.{entry}, consent, &diags);
    try testing.expectEqual(@as(usize, 0), diags.items.items.len);
    try testing.expect(engine.store.lookup(.fromString("orbiter:models.orbiter")) != null);
    if (!consented) {
        try testing.expect(native.canLoadWorld());
        try testing.expectEqual(@as(usize, 0), native.loader.loaded.items.len);
        try testing.expectEqual(@as(u32, 0), native.instances.instances.count());
        try testing.expectEqual(@as(u32, 0), native.instances.lights.count());
        try testing.expectEqual(baseline_bodies, walk.world.bodies.count());
        try testing.expectEqual(baseline_systems, orrery.world.systemCount());
        return 0;
    }
    try testing.expect(native.orbiter_owner != null);
    try testing.expect(!native.canLoadWorld());
    try testing.expectEqual(@as(u32, 1), native.instances.instances.count());
    try testing.expectEqual(@as(u32, 1), native.instances.lights.count());
    try testing.expectEqual(baseline_entities + 2, orrery.world.entityCount());
    try testing.expectEqual(baseline_systems + 1, orrery.world.systemCount());
    const solid = walk.world.body(native.body().?).?;
    try testing.expectEqualDeep(core.math.Vec3.init(0.4, 0.5, 0.25), solid.shape.box.half_extents);
    try testing.expectError(error.OrbiterNotDrawn, native.proveBlocking(&walk, dt));
    const solid_handle = native.body().?;
    const healthy_pose = walk.world.body(solid_handle).?.pose;
    var wrong_pose = healthy_pose;
    wrong_pose.rotation = .fromAxisAngle(.up, 0.4);
    _ = try walk.world.setPose(gpa, solid_handle, wrong_pose);
    try testing.expectError(error.OrbiterStateMismatch, native.record());
    _ = try walk.world.setPose(gpa, solid_handle, healthy_pose);
    // A stationary native writer cannot pass merely because it has live objects.
    for (0..Native.proof_ticks - 1) |_| try native.record();
    try testing.expectError(error.OrbiterDidNotMove, native.record());
    native.ticks = 0;
    native.hash = 0xcbf29ce484222325;
    native.first = null;
    for (0..Native.proof_ticks) |tick| {
        orrery.step(.{ .tick = tick, .delta = engine.step_delta });
        try native.record();
    }
    var retained = native.instances.instances.iterator();
    const instance = retained.next().?.id;
    try native.instances.setVisible(instance, false);
    try renderer.begin(.{ .camera = .{}, .target_size = .{ .width = 64, .height = 64 } });
    try native.submit(&content, &renderer);
    try testing.expect(!native.submitted); // A light alone is not a model submission.
    try testing.expectError(error.OrbiterNotDrawn, native.proveBlocking(&walk, dt));
    try native.instances.setVisible(instance, true);
    try renderer.begin(.{ .camera = .{}, .target_size = .{ .width = 64, .height = 64 } });
    try native.submit(&content, &renderer);
    try testing.expectEqual(@as(usize, 1), renderer.draws.items.len);
    try testing.expectEqual(@as(u32, 1), renderer.light_count);
    const material = renderer.materials.getConst(renderer.draws.items[0].material).?.desc;
    try testing.expect(material.shading.eql(render3d.lit_id));
    try testing.expectEqual(@as(f32, 0.7), material.base_color[2]);
    try testing.expect(native.submitted);
    try native.proveBlocking(&walk, dt);
    try testing.expect(native.blocked);
    var tour: Tour = .{ .emit = false };
    while (!tour.done()) try tour.advance(&walk, dt);
    try testing.expect(tour.failed == null);
    try testing.expectEqual(@as(u64, 0xcb99ccfcf2b6d6c3), tour.hash);
    const fingerprint = native.hash;
    // The cost-mode bound uses actual plinth content, not a synthetic renderer object.
    const plinth_bytes = try engine.os.readFile(gpa, options.plinth_package, 16 * 1024 * 1024);
    defer gpa.free(plinth_bytes);
    const plinth = try engine.store.add(gpa, "plinth:content", plinth_bytes, &engine.schemas, &diags);
    try engine.assets.mount(gpa, plinth, options.plinth_generated);
    try native.fillStress();
    try testing.expectEqual(@as(u32, 1024), native.instances.instances.count());
    try testing.expectError(error.TooManyInstances, native.instances.create(&content, 0, .fromString("plinth:models.plinth"), .identity));
    try renderer.begin(.{ .camera = .{}, .target_size = .{ .width = 64, .height = 64 } });
    try native.submit(&content, &renderer);
    try testing.expectEqual(@as(usize, 1024), renderer.draws.items.len);
    native.deinit();
    live = false;
    try testing.expectEqual(baseline_bodies, walk.world.bodies.count());
    try testing.expectEqual(baseline_entities, orrery.world.entityCount());
    try testing.expectEqual(@as(u32, 0), content.models.count());
    // Unbound, inactive registered trampoline remains safe while its image stays mapped.
    orrery.step(.{ .tick = Native.proof_ticks + 1, .delta = engine.step_delta });
    return fingerprint;
}

test "native3d: unconsented package retains content and creates no code registrations or objects" {
    if (comptime !options.available) return error.SkipZigTest;
    try testing.expectEqual(@as(u64, 0), try proof(false));
}

test "native3d: real C99 orbiter moves, submits lit, blocks player, replays and cleans up" {
    if (comptime !options.available) return error.SkipZigTest;
    const first = try proof(true);
    try testing.expect(first != 0);
    try testing.expectEqual(first, try proof(true));
}
