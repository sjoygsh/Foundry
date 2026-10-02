//! The same compiled content mod and assets an external user selects, not synthetic geometry.
const std = @import("std");
const app = @import("app");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const physics = @import("physics3d");
const render3d = @import("render3d");
const Props = @import("props.zig").Props;
const Settings = @import("props.zig").Settings;
const Walk = @import("walk.zig").Walk;
const Tour = @import("tour.zig").Tour;
const options = @import("walk_test_options");
const testing = std.testing;
const dt = core.time.Timestep.fromHz(60).elapsedAt(1).toSecondsF32();

fn engineInit() !*app.Engine {
    const engine = try app.Engine.init(testing.allocator, .{ .headless = true, .workers = 0, .content_dir = options.generated, .content = &.{
        .{ .base_dir = std.fs.path.dirname(options.core_package).?, .file = std.fs.path.basename(options.core_package), .root = "core-assets" },
        .{ .base_dir = std.fs.path.dirname(options.package).?, .file = std.fs.path.basename(options.package), .root = "sandbox3d-assets" },
    } });
    errdefer engine.deinit();
    try engine.assets.registerLoader(testing.allocator, asset.collisionMeshLoader());
    return engine;
}
fn addPlinth(engine: *app.Engine) !struct { bytes: []u8, handle: data.store.PackageHandle } {
    const gpa = testing.allocator;
    const bytes = try engine.os.readFile(gpa, options.plinth_package, 16 * 1024 * 1024);
    errdefer gpa.free(bytes);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    const handle = try engine.store.add(gpa, "plinth:content", bytes, &engine.schemas, &diags);
    try engine.assets.mount(gpa, handle, options.plinth_generated);
    return .{ .bytes = bytes, .handle = handle };
}

test "props: compiled plinth draws lit, blocks actual player, and refresh retires collision and model acquisitions" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const engine = try engineInit();
    defer engine.deinit();
    var renderer = try render3d.Renderer.init(gpa, engine.gpu, .{ .cull = false });
    defer renderer.deinit();
    var content = render3d.Content.init(gpa, &renderer, &engine.assets, .default);
    defer content.deinit();
    var walk = Walk.init(gpa);
    defer walk.deinit(&engine.assets);
    walk.refresh(&engine.store, &engine.assets, dt);
    var props: Props = .{};
    defer props.deinit(gpa, &walk.world, &content, &engine.assets);
    try props.refresh(gpa, &engine.store, &walk.world, &content, &engine.assets);
    try testing.expectEqual(@as(usize, 0), props.len);
    const baseline_bodies = walk.world.bodies.count();
    const baseline_meshes = walk.world.meshes.count();
    const mod = try addPlinth(engine);
    defer gpa.free(mod.bytes);
    try props.refresh(gpa, &engine.store, &walk.world, &content, &engine.assets);
    try testing.expectEqual(@as(usize, 1), props.len);
    try testing.expectEqual(@as(usize, 0), props.rejected);
    const entry = props.entries[0];
    try testing.expect(entry.id.eql(Props.plinth_id));
    const body = walk.world.body(entry.body).?;
    try testing.expectEqual(physics.BodyKind.static, body.kind);
    try testing.expectEqual(entry.id.hash, body.user);
    try testing.expectEqualDeep(entry.settings.position, body.pose.position);
    try testing.expectError(error.PlinthNotDrawn, props.provePlinth(&walk, dt));
    try renderer.begin(.{ .camera = .{}, .target_size = .{ .width = 64, .height = 64 } });
    try props.draw(&content);
    try testing.expectEqual(@as(usize, 1), renderer.draws.items.len);
    try testing.expectEqualDeep(entry.settings.matrix(), renderer.draws.items[0].world);
    const material = renderer.materials.getConst(renderer.draws.items[0].material).?.desc;
    try testing.expect(material.shading.eql(render3d.lit_id));
    try testing.expectEqual(@as(f32, 0.9), material.roughness);
    try props.provePlinth(&walk, dt);
    // Full old tours remain usable with the actual mod in their world.
    var tour: Tour = .{ .emit = false };
    while (!tour.done()) try tour.advance(&walk, dt);
    try testing.expect(tour.failed == null);
    try testing.expectEqual(@as(u64, 0xcb99ccfcf2b6d6c3), tour.hash);
    const feet = walk.result.feet;
    const character = walk.character;
    try props.refresh(gpa, &engine.store, &walk.world, &content, &engine.assets);
    try testing.expect(walk.world.body(entry.body) == null);
    try testing.expect(content.models.getConst(entry.model) == null);
    try testing.expectEqualDeep(feet, walk.result.feet);
    try testing.expectEqualDeep(character, walk.character);
    try testing.expectEqual(baseline_bodies + 1, walk.world.bodies.count());
    try testing.expectEqual(baseline_meshes + 1, walk.world.meshes.count());
    // No record means no cached body/model remains, not an invisible wall after disable.
    var empty: data.Store = .init(gpa, .default);
    defer empty.deinit(gpa);
    try props.refresh(gpa, &empty, &walk.world, &content, &engine.assets);
    try testing.expectEqual(@as(usize, 0), props.len);
    try testing.expectEqual(baseline_bodies, walk.world.bodies.count());
    try testing.expectEqual(baseline_meshes, walk.world.meshes.count());
    try testing.expectEqual(@as(u32, 0), content.models.count());
}

test "props: every field validates finite bounded values and scaled collision refuses, decorative scale works" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const engine = try engineInit();
    defer engine.deinit();
    const mod = try addPlinth(engine);
    defer gpa.free(mod.bytes);
    const record = engine.store.lookup(Props.plinth_id).?;
    const good = try Settings.read(record.fields);
    try testing.expectEqual(@as(f32, 1), good.scale);
    try testing.expectEqual(@as(f32, 0), good.yaw);
    const block = try gpa.dupe(u8, record.fields.block);
    defer gpa.free(block);
    var edited = record.fields;
    edited.block = block;
    for (record.schema.fields, 0..) |field, i| {
        @memcpy(block, record.fields.block);
        block[i / 8] &= ~(@as(u8, 1) << @intCast(i % 8));
        if (std.mem.eql(u8, field.name, "collision")) {
            try testing.expect((try Settings.read(edited)).collision.isNone());
        } else try testing.expectError(error.InvalidProp, Settings.read(edited));
        const at = offset(record.schema.fields, i);
        if (field.type == .f32) {
            for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 101, -101 }) |value| {
                @memcpy(block, record.fields.block);
                std.mem.writeInt(u32, block[at..][0..4], @bitCast(value), .little);
                try testing.expectError(error.InvalidProp, Settings.read(edited));
            }
        } else if (field.type == .nested) {
            for (field.type.nested, 0..) |_, n| {
                const position_at = at + offset(field.type.nested, n);
                for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 8193, -8193 }) |value| {
                    @memcpy(block, record.fields.block);
                    std.mem.writeInt(u32, block[position_at..][0..4], @bitCast(value), .little);
                    try testing.expectError(error.InvalidProp, Settings.read(edited));
                }
            }
        }
    }
    @memcpy(block, record.fields.block);
    std.mem.writeInt(u64, block[offset(record.schema.fields, 0)..][0..8], 0, .little);
    try testing.expectError(error.InvalidProp, Settings.read(edited));
    const scale_at = offset(record.schema.fields, 3);
    for ([_]f32{ 0, -1 }) |scale| {
        @memcpy(block, record.fields.block);
        std.mem.writeInt(u32, block[scale_at..][0..4], @bitCast(scale), .little);
        try testing.expectError(error.InvalidProp, Settings.read(edited));
    }
    @memcpy(block, record.fields.block);
    std.mem.writeInt(u32, block[scale_at..][0..4], @bitCast(@as(f32, 2)), .little);
    try testing.expectError(error.ScaledCollision, Settings.read(edited));
    std.mem.writeInt(u64, block[offset(record.schema.fields, 4)..][0..8], 0, .little);
    const decorative = try Settings.read(edited);
    try testing.expectEqual(@as(f32, 2), decorative.scale);
    try testing.expectEqual(@as(f32, 2), decorative.matrix().cols[0][0]);
}

fn offset(fields: []const data.schema.Field, index: usize) usize {
    var cursor: usize = data.fpk.presenceBytes(fields.len);
    for (fields, 0..) |field, i| {
        cursor = std.mem.alignForward(usize, cursor, data.fpk.alignOf(field.type));
        if (i == index) return cursor;
        cursor += data.fpk.sizeOf(field.type);
    }
    unreachable;
}

fn compile(engine: *app.Engine, source: []const u8) ![]u8 {
    const gpa = testing.allocator;
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var document = try data.parser.parse(gpa, "props.fdt", source, .{ .namespace = "extra" }, &diags);
    defer document.deinit(gpa);
    var package = try data.Package.init(gpa, "extra:content", 1, .default);
    defer package.deinit(gpa);
    try package.addDocument(gpa, &document, &engine.schemas, &diags);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    try data.fpk.write(gpa, &package, &engine.schemas, &bytes);
    return bytes.toOwnedSlice(gpa);
}

test "props: every merged record is hash ordered, invalid acquisitions roll back, and the set limit refuses instead of truncating" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const engine = try engineInit();
    defer engine.deinit();
    const mod = try addPlinth(engine);
    defer gpa.free(mod.bytes);
    var renderer = try render3d.Renderer.init(gpa, engine.gpu, .{ .cull = false });
    defer renderer.deinit();
    var content = render3d.Content.init(gpa, &renderer, &engine.assets, .default);
    defer content.deinit();
    var world: physics.World = .{};
    defer world.deinit(gpa);
    var props: Props = .{};
    defer props.deinit(gpa, &world, &content, &engine.assets);
    const bytes = try compile(engine,
        \\sandbox3d:prop extra:props.a { model plinth:models.plinth position { x 1 y 0 z 0 } yaw -0.5 collision plinth:models.plinth.collision }
        \\sandbox3d:prop extra:props.z { model plinth:models.plinth position { x 2 y 0 z 0 } yaw 1 scale 2 }
        \\sandbox3d:prop extra:props.missing_model { model extra:missing position { x 0 y 0 z 0 } }
        \\sandbox3d:prop extra:props.wrong_model { model plinth:materials.stone position { x 0 y 0 z 0 } }
        \\sandbox3d:prop extra:props.skinned { model sandbox3d:models.walker position { x 0 y 0 z 0 } }
        \\sandbox3d:prop extra:props.missing_collision { model plinth:models.plinth position { x 0 y 0 z 0 } collision extra:missing }
        \\sandbox3d:prop extra:props.wrong_collision { model plinth:models.plinth position { x 0 y 0 z 0 } collision plinth:materials.stone }
        \\sandbox3d:prop extra:props.scaled_collision { model plinth:models.plinth position { x 0 y 0 z 0 } scale 2 collision plinth:models.plinth.collision }
    );
    defer gpa.free(bytes);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    _ = try engine.store.add(gpa, "extra:content", bytes, &engine.schemas, &diags);
    try props.refresh(gpa, &engine.store, &world, &content, &engine.assets);
    try testing.expectEqual(@as(usize, 3), props.len);
    try testing.expectEqual(@as(usize, 6), props.rejected);
    for (props.entries[1..props.len], props.entries[0 .. props.len - 1]) |next, previous| try testing.expect(previous.id.hash < next.id.hash);
    try testing.expectEqual(@as(u32, 1), content.models.count());
    try testing.expectEqual(@as(u32, 2), world.bodies.count());
    for (props.entries[0..props.len]) |entry| if (!entry.body.isNone()) {
        const body = world.body(entry.body).?;
        try testing.expectEqualDeep(entry.settings.position, body.pose.position);
        try testing.expectEqualDeep(entry.settings.rotation(), body.pose.rotation);
    };
    try renderer.begin(.{ .camera = .{}, .target_size = .{ .width = 64, .height = 64 } });
    try props.draw(&content);
    try testing.expectEqual(@as(usize, 3), renderer.draws.items.len);
    for (props.entries[0..props.len], renderer.draws.items) |entry, draw| try testing.expectEqualDeep(entry.settings.matrix(), draw.world);
    // The source compiler's declaration order differs from hash order; overrides do not
    // move records in Store, so the follower must explicitly re-sort on every refresh.
    var many_source: std.ArrayList(u8) = .empty;
    defer many_source.deinit(gpa);
    for (0..Props.max_props + 1) |i| {
        const line = try std.fmt.allocPrint(gpa, "sandbox3d:prop extra:props.n{d} {{ model plinth:models.plinth position {{ x 0 y 0 z 0 }} }}\n", .{i});
        defer gpa.free(line);
        try many_source.appendSlice(gpa, line);
    }
    const many = try compile(engine, many_source.items);
    defer gpa.free(many);
    var many_store: data.Store = .init(gpa, .default);
    defer many_store.deinit(gpa);
    _ = try many_store.add(gpa, "extra:content", many, &engine.schemas, &diags);
    try testing.expectError(error.TooManyProps, props.refresh(gpa, &many_store, &world, &content, &engine.assets));
    try testing.expectEqual(@as(usize, 0), props.len);
    try testing.expectEqual(@as(u32, 0), world.bodies.count());
    try testing.expectEqual(@as(u32, 0), world.meshes.count());
    try testing.expectEqual(@as(u32, 0), content.models.count());
}

test "props: collision source reload is copied fresh and failed reload preserves its last valid asset" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const engine = try engineInit();
    defer engine.deinit();
    const mod = try addPlinth(engine);
    defer gpa.free(mod.bytes);
    var renderer = try render3d.Renderer.init(gpa, engine.gpu, .{});
    defer renderer.deinit();
    var content = render3d.Content.init(gpa, &renderer, &engine.assets, .default);
    defer content.deinit();
    var world: physics.World = .{};
    defer world.deinit(gpa);
    var props: Props = .{};
    defer props.deinit(gpa, &world, &content, &engine.assets);
    try props.refresh(gpa, &engine.store, &world, &content, &engine.assets);
    const before = props.entries[0];
    const record = engine.store.lookup(before.settings.collision).?;
    const source = (try record.fields.stringAt(record.schema.fieldIndex("source").?)).?;
    const asset_bytes = try engine.os.readFileConfined(gpa, options.plinth_generated, source, 1024 * 1024);
    defer gpa.free(asset_bytes.bytes);
    var geometry = try (try asset.collision_mesh.read(asset_bytes.bytes, .default)).copy(gpa);
    defer geometry.deinit(gpa);
    for (geometry.positions) |*position| position.y += 0.1;
    const changed = try asset.collision_mesh.write(gpa, geometry.positions, geometry.indices);
    defer gpa.free(changed);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try tmp.dir.realPath(testing.io, &path_buffer);
    const root = path_buffer[0..path_length];
    const path = try @import("platform").os.joinPath(gpa, &.{ root, source });
    defer gpa.free(path);
    try engine.os.createDirPath(std.fs.path.dirname(path).?);
    try engine.os.writeFile(path, changed);
    try engine.assets.mount(gpa, mod.handle, root);
    try engine.assets.reload(gpa, before.asset_handle);
    try props.refresh(gpa, &engine.store, &world, &content, &engine.assets);
    try testing.expect(world.body(before.body) == null);
    try testing.expectEqual(@as(usize, 1), props.len);
    const hit = (try world.raycast(before.settings.position.add(.init(0, 3, 0)), .init(0, -1, 0), 4, .{})).?;
    try testing.expectApproxEqAbs(@as(f32, 1.3), hit.point.y, 0.001);
    try testing.expect(hit.body.eql(props.entries[0].body));
    try engine.os.writeFile(path, "not a collision mesh");
    try testing.expectError(error.InvalidAsset, engine.assets.reload(gpa, props.entries[0].asset_handle));
    try props.refresh(gpa, &engine.store, &world, &content, &engine.assets);
    const retained = (try world.raycast(before.settings.position.add(.init(0, 3, 0)), .init(0, -1, 0), 4, .{})).?;
    try testing.expectApproxEqAbs(@as(f32, 1.3), retained.point.y, 0.001);
    try testing.expectEqual(@as(u32, 1), world.bodies.count());
    // Scratch deliberately contains no visual mesh. Content can accept the model but
    // submit no resident part; that must never count as the tour having drawn the plinth.
    try engine.os.writeFile(path, changed);
    props.deinit(gpa, &world, &content, &engine.assets);
    _ = engine.assets.evictUnused(gpa);
    try props.refresh(gpa, &engine.store, &world, &content, &engine.assets);
    try testing.expectEqual(@as(usize, 1), props.len);
    try renderer.begin(.{ .camera = .{}, .target_size = .{ .width = 64, .height = 64 } });
    try props.draw(&content);
    try testing.expectEqual(@as(usize, 0), renderer.draws.items.len);
    try testing.expect(!props.entries[0].submitted);
}
