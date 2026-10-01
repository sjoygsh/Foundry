//! M25 Step 1: `render3d.Instances` against compiled packages (`docs/design/public3d.md`
//! §4 and §12). The set is what a mod's calls will fill, so every refusal is shown leaving
//! nothing acquired, and every acquisition is shown released.

const std = @import("std");
const platform = @import("platform");
const author = @import("author");
const render3d = @import("render3d");

const model_content = @import("model_content.zig");

const testing = std.testing;
const Mat4 = @import("core").math.Mat4;
const Stack = model_content.Stack;
const id = model_content.id;

const wide_records =
    \\foundry:model demo:models.wide {
    \\    slots [ { name "s0" material demo:materials.red } { name "s1" material demo:materials.red } { name "s2" material demo:materials.red }
    \\            { name "s3" material demo:materials.red } { name "s4" material demo:materials.red } { name "s5" material demo:materials.red }
    \\            { name "s6" material demo:materials.red } { name "s7" material demo:materials.red } { name "s8" material demo:materials.red } ]
    \\    parts [ { mesh demo:meshes.quad submesh 0 slot 0 translation { x 0 y 0 z 0 } rotation { x 0 y 0 z 0 w 1 } scale { x 1 y 1 z 1 } } ]
    \\}
;

fn at(z: f32) Mat4 {
    return Mat4.translation(.init(0, 0, z));
}

/// What `Content` holds, so a test can show it is back where it started.
const Held = struct {
    models: u32,
    materials: u32,
    assets: u32,

    fn of(stack: *Stack) Held {
        return .{ .models = stack.content.models.count(), .materials = stack.content.materials.count(), .assets = stack.assets.count() };
    }
};

test "M25 instances refuse what they must, draw in slot order and release what they hold" {
    const stack = try model_content.recordStack();
    defer stack.deinit();
    try stack.write("wide.fdt", wide_records);
    try stack.build();
    var set = try render3d.Instances.init(stack.gpa, .{ .max_instances = 3 });
    defer set.deinit(&stack.content);
    const empty = Held.of(stack);

    // Refusals at create hold nothing.
    try testing.expectError(error.ModelNotFound, set.create(&stack.content, 1, id("demo:models.absent"), .identity));
    try testing.expectError(error.NotAModel, set.create(&stack.content, 1, id("demo:materials.red"), .identity));
    try testing.expectError(error.InvalidModelRecord, set.create(&stack.content, 1, id("demo:models.no_slot"), .identity));
    var projective = Mat4.identity;
    projective.cols[2][3] = -1;
    try testing.expectError(error.InvalidTransform, set.create(&stack.content, 1, id("demo:models.pair"), projective));
    var nan = Mat4.identity;
    nan.cols[3][0] = std.math.nan(f32);
    try testing.expectError(error.InvalidTransform, set.create(&stack.content, 1, id("demo:models.pair"), nan));
    try testing.expectEqual(empty, Held.of(stack));

    const a = try set.create(&stack.content, 1, id("demo:models.pair"), at(-1));
    const b = try set.create(&stack.content, 2, id("demo:models.pair"), at(-2));
    try testing.expectEqual(@as(?u64, 1), set.instanceOwner(a));
    try testing.expectEqual(@as(?u64, 2), set.instanceOwner(b));
    const one_pair = Held.of(stack);

    // Overrides: refused without change, then one per slot, replaced and cleared.
    try testing.expectError(error.InvalidOverride, set.setMaterial(&stack.content, a, 2, id("demo:materials.crate")));
    try testing.expectError(error.MaterialNotFound, set.setMaterial(&stack.content, a, 0, id("demo:materials.absent")));
    try testing.expectError(error.NotAMaterial, set.setMaterial(&stack.content, a, 0, id("demo:models.pair")));
    try testing.expectError(error.InvalidHandle, set.setMaterial(&stack.content, .none, 0, id("demo:materials.crate")));
    try testing.expectEqual(one_pair, Held.of(stack));
    try set.setMaterial(&stack.content, a, 0, id("demo:materials.too_bright"));
    try testing.expectEqual(one_pair.materials + 1, stack.content.materials.count());
    try set.setMaterial(&stack.content, a, 0, id("demo:materials.crate"));
    // The replaced material was released; crate is already one of pair's slots.
    try testing.expectEqual(one_pair.materials, stack.content.materials.count());
    try set.setMaterial(&stack.content, b, 1, id("demo:materials.red"));
    try set.setMaterial(&stack.content, b, 1, null);
    try set.setMaterial(&stack.content, b, 1, null);

    try testing.expectError(error.InvalidTransform, set.setWorld(a, projective));
    try testing.expectError(error.InvalidHandle, set.setWorld(.none, at(-1)));
    try testing.expectError(error.InvalidHandle, set.setVisible(.none, false));

    const crate = try stack.content.acquireMaterial(id("demo:materials.crate"));
    defer stack.content.releaseMaterial(crate);
    try stack.begin();
    try set.submit(&stack.content, &stack.renderer);
    // Two drawable parts each, `a` then `b`: slot order, and the override on `a`'s slot 0.
    try testing.expectEqual(@as(usize, 4), stack.renderer.draws.items.len);
    for (stack.renderer.draws.items, [_]f32{ -1, -1, -2, -2 }) |draw, z| try testing.expectEqual(z, draw.world.cols[3][2]);
    try testing.expect(stack.renderer.draws.items[0].material.eql(crate));
    try testing.expect(!stack.renderer.draws.items[2].material.eql(crate));
    try stack.finish(null);
    try testing.expectEqual(@as(u32, 0), stack.renderer.frameStats().instances_refused);

    // Hidden draws nothing and keeps its acquisitions; moved draws where it was moved.
    try set.setVisible(a, false);
    try set.setWorld(b, at(-3));
    try stack.begin();
    try set.submit(&stack.content, &stack.renderer);
    try testing.expectEqual(@as(usize, 2), stack.renderer.draws.items.len);
    try testing.expectEqual(@as(f32, -3), stack.renderer.draws.items[0].world.cols[3][2]);
    try stack.finish(null);

    // The bound, checked before acquisition.
    const c = try set.create(&stack.content, 3, id("demo:models.wide"), at(-1));
    const with_wide = Held.of(stack);
    try testing.expectError(error.TooManyInstances, set.create(&stack.content, 3, id("demo:models.pair"), at(-1)));
    try testing.expectEqual(with_wide, Held.of(stack));
    // Eight overrides, and a ninth slot refused; a replacement still fits.
    for (0..render3d.instances.max_overrides) |slot| try set.setMaterial(&stack.content, c, @intCast(slot), id("demo:materials.crate"));
    try testing.expectError(error.TooManyOverrides, set.setMaterial(&stack.content, c, 8, id("demo:materials.crate")));
    try set.setMaterial(&stack.content, c, 7, id("demo:materials.red"));

    // Destroying gives everything back; the handles are stale, and stay so after reuse.
    try set.destroy(&stack.content, c);
    try testing.expectEqual(one_pair, Held.of(stack));
    try set.destroy(&stack.content, a);
    try set.destroy(&stack.content, b);
    try testing.expectError(error.InvalidHandle, set.destroy(&stack.content, a));
    try testing.expect(set.instanceOwner(a) == null);
    const reused = try set.create(&stack.content, 4, id("demo:models.pair"), at(-1));
    try testing.expect(reused.index == b.index or reused.index == a.index);
    try testing.expectError(error.InvalidHandle, set.setWorld(a, at(0)));
    try testing.expectError(error.InvalidHandle, set.setWorld(b, at(0)));
    try set.destroy(&stack.content, reused);
    // `crate` is still held by this test; everything else is back to empty.
    try testing.expectEqual(empty.models, stack.content.models.count());
    try testing.expectEqual(empty.materials + 1, stack.content.materials.count());
    try testing.expectEqual(@as(usize, 0), stack.violations());
}

test "M25 retained lights follow the host's, and a full frame drops them, not the host's" {
    const stack = try model_content.recordStack();
    defer stack.deinit();
    var set = try render3d.Instances.init(stack.gpa, .{ .max_lights = 3 });
    defer set.deinit(&stack.content);
    var handles: [3]render3d.InstanceLightHandle = undefined;
    for (&handles, 0..) |*handle, i| handle.* = try set.createLight(9, .{ .kind = .point, .intensity = 10, .range = 4, .world = Mat4.translation(.init(@floatFromInt(i), 1, -2)) });
    try set.destroyLight(handles[1]);
    handles[1] = try set.createLight(9, .{ .kind = .spot, .intensity = 10, .range = 4, .world = Mat4.translation(.init(5, 1, -2)) });

    try stack.begin();
    try set.submit(&stack.content, &stack.renderer);
    try testing.expectEqual(@as(u32, 3), stack.renderer.light_count);
    // Slot order: the reused slot keeps its place between the other two.
    for (stack.renderer.lights[0..3], [_]f32{ 0, 5, 2 }) |light, x| try testing.expectEqual(x, light.world.cols[3][0]);
    try stack.finish(null);
    try testing.expectEqual(@as(u32, 0), stack.renderer.frameStats().instance_lights_dropped);

    try stack.begin();
    for (0..render3d.max_lights - 1) |_| try stack.renderer.addLight(.{ .kind = .directional, .intensity = 1, .world = .identity });
    try set.submit(&stack.content, &stack.renderer);
    try testing.expectEqual(@as(u32, render3d.max_lights), stack.renderer.light_count);
    try testing.expectEqual(@as(f32, 0), stack.renderer.lights[render3d.max_lights - 1].world.cols[3][0]);
    try stack.finish(null);
    try testing.expectEqual(@as(u32, 2), stack.renderer.frameStats().instance_lights_dropped);
    try testing.expectEqual(@as(u32, render3d.max_lights), stack.renderer.frameStats().lights);

    // Outside a frame, submission is the host's mistake and is an error, never a count.
    try testing.expectError(error.NotRecording, set.submit(&stack.content, &stack.renderer));
}

const plain_records =
    \\foundry:mesh demo:plain.mesh { source "meshes/quad.fmesh" }
    \\foundry:model demo:plain.model {
    \\ slots [ { name "main" material demo:skin.material } ]
    \\ parts [ { mesh demo:plain.mesh submesh 0 slot 0 translation { x 0 y 0 z 0 } rotation { x 0 y 0 z 0 w 1 } scale { x 1 y 1 z 1 } } ]
    \\}
;

test "M25 a skinned model is unsupported, and one reloaded into it is counted at submit" {
    const stack = try model_content.animationStack(1, 1, model_content.animation_records);
    defer stack.deinit();
    const quad = try model_content.quadFile(stack.gpa);
    defer stack.gpa.free(quad);
    try stack.install("meshes/quad.fmesh", quad);
    try stack.write("plain.fdt", plain_records);
    try stack.build();
    var set = try render3d.Instances.init(stack.gpa, .default);
    defer set.deinit(&stack.content);

    try testing.expectError(error.Unsupported, set.create(&stack.content, 1, id("demo:skin.model"), .identity));
    try testing.expectEqual(@as(u32, 0), stack.content.models.count());
    const plain = try set.create(&stack.content, 1, id("demo:plain.model"), at(0));
    try stack.begin();
    try set.submit(&stack.content, &stack.renderer);
    try testing.expectEqual(@as(usize, 1), stack.renderer.draws.items.len);
    try stack.finish(null);

    // The same ID now names a skeleton and a skinned mesh. The handle stays valid; the
    // draw is refused, recorded as nothing, counted, and the frame goes on.
    const skinned = try std.mem.replaceOwned(u8, stack.gpa, plain_records, "mesh demo:plain.mesh submesh", "mesh demo:skin.mesh submesh");
    defer stack.gpa.free(skinned);
    const rigged = try std.mem.replaceOwned(u8, stack.gpa, skinned, " parts [", " skeleton demo:skin.rig\n parts [");
    defer stack.gpa.free(rigged);
    try stack.write("plain.fdt", rigged);
    try stack.reload();
    try testing.expect(stack.content.isSkinned(set.instances.getConst(plain).?.model));
    try stack.begin();
    try set.submit(&stack.content, &stack.renderer);
    try testing.expectEqual(@as(usize, 0), stack.renderer.draws.items.len);
    try stack.finish(null);
    try testing.expectEqual(@as(u32, 1), stack.renderer.frameStats().instances_refused);
    try set.destroy(&stack.content, plain);
    try testing.expectEqual(@as(u32, 0), stack.content.models.count());
    try testing.expectEqual(@as(usize, 0), stack.violations());
}

test "M25 another package's material override reaches a retained instance at the next frame" {
    const stack = try model_content.recordStack();
    defer stack.deinit();
    var set = try render3d.Instances.init(stack.gpa, .default);
    defer set.deinit(&stack.content);
    const instance = try set.create(&stack.content, 1, id("demo:models.pair"), at(-1));
    // Out of range in the base package, so drawn as the placeholder until the mod fixes it.
    try set.setMaterial(&stack.content, instance, 1, id("demo:materials.too_bright"));

    try stack.begin();
    try set.submit(&stack.content, &stack.renderer);
    try testing.expectEqual(render3d.content.placeholder.base_color, stack.materialDesc(stack.renderer.draws.items[1].material).base_color);
    try stack.finish(null);

    // A second package that overrides the record, loaded after the first, as a mod is.
    try stack.writeUnder(stack.out, "demo.fpk", stack.bytes.items);
    const base_path = try platform.os.joinPath(stack.gpa, &.{ stack.out, "demo.fpk" });
    defer stack.gpa.free(base_path);
    var deps = try author.dependency.Set.load(stack.gpa, stack.os, &.{.{ .path = base_path }}, .default, &stack.diags);
    defer deps.deinit();
    const mod_src = try platform.os.joinPath(stack.gpa, &.{ stack.src, "mod-source" });
    defer stack.gpa.free(mod_src);
    try stack.writeUnder(mod_src, "mod.fdt",
        \\foundry:mod tint:content { name "Tint" version 1 license "Apache-2.0" requires [{ id demo:content }] }
        \\foundry:material demo:materials.too_bright { base_color { r 0 g 0 b 1 a 1 } }
    );
    var mod_bytes: std.ArrayList(u8) = .empty;
    defer mod_bytes.deinit(stack.gpa);
    const identity = try author.compile(stack.gpa, stack.os, mod_src, .{ .dependencies = &deps }, &stack.schemas, &stack.diags, &mod_bytes);
    defer stack.gpa.free(identity.name);
    stack.assets.clearMounts();
    stack.store.deinit(stack.gpa);
    stack.store = .init(stack.gpa, .default);
    for ([_]struct { []const u8, []const u8 }{ .{ "demo:content", stack.bytes.items }, .{ "tint:content", mod_bytes.items } }) |package| {
        const handle = try stack.store.add(stack.gpa, package[0], package[1], &stack.schemas, &stack.diags);
        try stack.assets.mount(stack.gpa, handle, stack.out);
    }
    _ = stack.assets.reloadAll(stack.gpa);
    try stack.content.contentChanged();

    try stack.begin();
    try set.submit(&stack.content, &stack.renderer);
    try testing.expectEqual([4]f32{ 0, 0, 1, 1 }, stack.materialDesc(stack.renderer.draws.items[1].material).base_color);
    // The slot the instance did not override still draws the model's own material.
    try testing.expect(!stack.renderer.draws.items[0].material.eql(stack.renderer.draws.items[1].material));
    try stack.finish(null);
    try testing.expectEqual(@as(usize, 0), stack.violations());
}
