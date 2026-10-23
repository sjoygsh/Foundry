//! M29 Step 5: `render3d.Particles` against compiled packages (`docs/design/particles.md` §6).
//! Records become running instances by handle. They are stepped, culled, prepared into runtime
//! meshes and drawn, and followed across a reload, and every refusal holds nothing.

const std = @import("std");
const core = @import("core");
const render3d = @import("render3d");

const model_content = @import("model_content.zig");

const testing = std.testing;
const Mat4 = core.math.Mat4;
const Stack = model_content.Stack;
const id = model_content.id;

const dt: f32 = 1.0 / 64.0;

const records =
    \\foundry:material demo:materials.spark { shading foundry:shading.particle  alpha_mode "blend"  emissive { r 1 g 0.5 b 0.2 }  emissive_strength 1 }
    \\foundry:material demo:materials.debris { shading foundry:shading.particle  alpha_mode "mask" }
    \\foundry:material demo:materials.lit { shading foundry:shading.lit }
    \\foundry:particle_emitter demo:fx.sparks { material demo:materials.spark  capacity 512  rate 640  lifetime { min 1 max 1 }  speed { min 0 max 0 } }
    \\foundry:particle_emitter demo:fx.debris { material demo:materials.debris  capacity 64  rate 64  speed { min 0 max 0 } }
    \\foundry:particle_emitter demo:fx.tiny { material demo:materials.spark  capacity 4  rate 6400 }
    \\foundry:particle_emitter demo:fx.wrong { material demo:materials.lit }
;

fn stackWith(text: []const u8) !*Stack {
    const stack = try Stack.init(1);
    errdefer stack.deinit();
    try stack.write("fx.fdt", text);
    try stack.build();
    return stack;
}

/// `Stack.begin`'s camera: at the origin, looking down −Z.
fn view() render3d.FrameView {
    return .{
        .camera = .{ .vertical_fov = std.math.pi / 2.0, .near = 0.1, .far = 10 },
        .target_size = .{ .width = model_content.target_size, .height = model_content.target_size },
    };
}

fn at(z: f32) Mat4 {
    return Mat4.translation(.init(0, 0, z));
}

test "M29 Particles refuse what they must and hold nothing for it" {
    const stack = try stackWith(records);
    defer stack.deinit();
    var effects = try render3d.Particles.init(stack.gpa, &stack.renderer, &stack.content, .{ .max_emitters = 2 });
    defer effects.deinit();
    try testing.expectError(error.InvalidConfig, render3d.Particles.init(stack.gpa, &stack.renderer, &stack.content, .{ .max_emitters = 0 }));
    const materials = stack.content.materials.count();

    try testing.expectError(error.EmitterNotFound, effects.create(.{ .emitter = id("demo:fx.absent") }));
    try testing.expectError(error.NotAnEmitter, effects.create(.{ .emitter = id("demo:materials.spark") }));
    // A lit material needs normals, which a particle mesh does not have.
    try testing.expectError(error.InvalidMaterial, effects.create(.{ .emitter = id("demo:fx.wrong") }));
    var nan = Mat4.identity;
    nan.cols[3][0] = std.math.nan(f32);
    try testing.expectError(error.InvalidTransform, effects.create(.{ .emitter = id("demo:fx.sparks"), .transform = nan }));
    try testing.expectEqual(materials, stack.content.materials.count());

    const a = try effects.create(.{ .emitter = id("demo:fx.sparks"), .transform = at(-3) });
    _ = try effects.create(.{ .emitter = id("demo:fx.sparks"), .transform = at(-3), .stream = 1 });
    try testing.expectError(error.TooManyEmitters, effects.create(.{ .emitter = id("demo:fx.debris") }));
    try testing.expectError(error.InvalidTransform, effects.setTransform(a, nan));
    try testing.expectError(error.InvalidHandle, effects.setTransform(.none, .identity));
    try testing.expectError(error.InvalidHandle, effects.stop(.none));
    try effects.destroy(a);
    try testing.expectError(error.InvalidHandle, effects.destroy(a));
    try testing.expectEqual(@as(?u32, null), effects.liveCount(a));
}

test "M29 an instance is stepped, prepared before the window, drawn inside it, and counted" {
    const stack = try stackWith(records);
    defer stack.deinit();
    var effects = try render3d.Particles.init(stack.gpa, &stack.renderer, &stack.content, .default);
    defer effects.deinit();
    const sparks = try effects.create(.{ .emitter = id("demo:fx.sparks"), .transform = at(-3) });
    const debris = try effects.create(.{ .emitter = id("demo:fx.debris"), .transform = at(-4) });

    for (0..32) |tick| try effects.step(tick, dt, core.jobs.serial);
    // 640 a second over half a second, each living a second.
    try testing.expectEqual(@as(?u32, 320), effects.liveCount(sparks));
    try effects.prepare(view(), core.jobs.serial);
    try stack.begin();
    // Writes are refused inside the window, as every runtime mesh's are.
    try testing.expectError(error.InFrame, effects.prepare(view(), core.jobs.serial));
    try effects.draw();
    const draws = stack.renderer.draws.items;
    try testing.expectEqual(@as(usize, 2), draws.len);
    // Expansion wrote world space, so the mesh is drawn as it is.
    for (draws) |draw| try testing.expectEqual(Mat4.identity, draw.world);
    // The blended sparks were sorted; the masked debris were not, and draws opaque first.
    try testing.expectEqual(render3d.AlphaMode.blend, draws[0].alpha);
    try testing.expectEqual(render3d.AlphaMode.mask, draws[1].alpha);
    try stack.finish(null);
    const stats = stack.renderer.frameStats();
    try testing.expectEqual(@as(u32, 2), stats.particle_emitters);
    try testing.expectEqual(@as(u32, 320 + effects.liveCount(debris).?), stats.particles);
    try testing.expectEqual(@as(u32, 0), stats.particle_emitters_culled);

    // Destroyed inside the window: the draw already submitted is still recorded, and its
    // mesh and material go when the window closes.
    try effects.step(32, dt, core.jobs.serial);
    try effects.prepare(view(), core.jobs.serial);
    try stack.begin();
    try effects.draw();
    try effects.destroy(sparks);
    try stack.finish(null);
    try testing.expectEqual(@as(usize, 0), stack.violations());
}

test "M29 an instance out of view is stepped but not uploaded or drawn" {
    const stack = try stackWith(records);
    defer stack.deinit();
    var effects = try render3d.Particles.init(stack.gpa, &stack.renderer, &stack.content, .default);
    defer effects.deinit();
    // Behind the camera, which looks down −Z.
    const behind = try effects.create(.{ .emitter = id("demo:fx.sparks"), .transform = at(5) });
    for (0..8) |tick| try effects.step(tick, dt, core.jobs.serial);
    try effects.prepare(view(), core.jobs.serial);
    try stack.begin();
    try effects.draw();
    try testing.expectEqual(@as(usize, 0), stack.renderer.draws.items.len);
    try stack.finish(null);
    const stats = stack.renderer.frameStats();
    try testing.expectEqual(@as(u32, 1), stats.particle_emitters_culled);
    try testing.expectEqual(@as(u32, 0), stats.particle_emitters);
    try testing.expectEqual(@as(u32, 0), stats.mesh_updates);
    try testing.expectEqual(@as(?u32, 80), effects.liveCount(behind));
}

test "M29 a full store's refused spawns are counted in the next frame" {
    const stack = try stackWith(records);
    defer stack.deinit();
    var effects = try render3d.Particles.init(stack.gpa, &stack.renderer, &stack.content, .default);
    defer effects.deinit();
    _ = try effects.create(.{ .emitter = id("demo:fx.tiny"), .transform = at(-3) });
    // 100 spawns due per tick into a store of 4.
    try effects.step(0, dt, core.jobs.serial);
    try effects.prepare(view(), core.jobs.serial);
    try stack.begin();
    try stack.finish(null);
    try testing.expectEqual(@as(u32, 96), stack.renderer.frameStats().particles_dropped);
}

test "M29 stepping over jobs gives the bytes a serial step gives" {
    const stack = try stackWith(records);
    defer stack.deinit();
    var serial = try render3d.Particles.init(stack.gpa, &stack.renderer, &stack.content, .default);
    defer serial.deinit();
    var reversed = try render3d.Particles.init(stack.gpa, &stack.renderer, &stack.content, .default);
    defer reversed.deinit();
    var handles: [2][3]render3d.ParticleEmitterHandle = undefined;
    for ([_]*render3d.Particles{ &serial, &reversed }, &handles) |set, *h| {
        for (h, 0..) |*handle, i| handle.* = try set.create(.{ .emitter = id("demo:fx.sparks"), .transform = at(-3), .stream = i });
    }
    for (0..40) |tick| {
        try serial.step(tick, dt, core.jobs.serial);
        try reversed.step(tick, dt, core.jobs.reversed);
    }
    for (handles[0], handles[1]) |a, b| try testing.expectEqual(serial.stateHash(a).?, reversed.stateHash(b).?);
    // Streams are separate sequences.
    try testing.expect(serial.stateHash(handles[0][0]).? != serial.stateHash(handles[0][1]).?);
}

test "M29 a reload keeps handles and particles, shrinks oldest first, and stops a removed record" {
    const stack = try stackWith(records);
    defer stack.deinit();
    var effects = try render3d.Particles.init(stack.gpa, &stack.renderer, &stack.content, .default);
    defer effects.deinit();
    const sparks = try effects.create(.{ .emitter = id("demo:fx.sparks"), .transform = at(-3) });
    for (0..32) |tick| try effects.step(tick, dt, core.jobs.serial);
    try testing.expectEqual(@as(?u32, 320), effects.liveCount(sparks));

    // A lower capacity and a different material: the handle and the newest 100 remain.
    const edited = try std.mem.replaceOwned(u8, stack.gpa, records, "material demo:materials.spark  capacity 512  rate 640", "material demo:materials.ember  capacity 100  rate 640");
    defer stack.gpa.free(edited);
    const with_ember = try std.mem.concat(stack.gpa, u8, &.{ edited, "\nfoundry:material demo:materials.ember { shading foundry:shading.particle  alpha_mode \"blend\" }\n" });
    defer stack.gpa.free(with_ember);
    try stack.write("fx.fdt", with_ember);
    try stack.reload();
    try effects.contentChanged();
    try effects.step(32, dt, core.jobs.serial);
    try testing.expectEqual(@as(?u32, 100), effects.liveCount(sparks));

    // The record removed: stopped, drawing nothing, counted, until a reload restores it.
    const without = try std.mem.replaceOwned(u8, stack.gpa, with_ember, "foundry:particle_emitter demo:fx.sparks", "foundry:particle_emitter demo:fx.renamed");
    defer stack.gpa.free(without);
    try stack.write("fx.fdt", without);
    try stack.reload();
    try effects.contentChanged();
    // Past every particle's one-second life: stepped, they would all have been replaced.
    const before = effects.stateHash(sparks).?;
    for (33..113) |tick| try effects.step(tick, dt, core.jobs.serial);
    try testing.expectEqual(before, effects.stateHash(sparks).?);
    try effects.prepare(view(), core.jobs.serial);
    try stack.begin();
    try effects.draw();
    try testing.expectEqual(@as(usize, 0), stack.renderer.draws.items.len);
    try stack.finish(null);
    try testing.expectEqual(@as(u32, 1), stack.renderer.frameStats().particle_emitters_refused);

    try stack.write("fx.fdt", with_ember);
    try stack.reload();
    try effects.contentChanged();
    try effects.step(113, dt, core.jobs.serial);
    try effects.prepare(view(), core.jobs.serial);
    try stack.begin();
    try effects.draw();
    try testing.expectEqual(@as(usize, 1), stack.renderer.draws.items.len);
    try stack.finish(null);
    try testing.expectEqual(@as(usize, 0), stack.violations());
}
