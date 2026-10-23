//! The effects corner against the compiled package and the `embers` mod an external user
//! selects (`particles.md` §8).
const std = @import("std");
const app = @import("app");
const asset = @import("asset");
const core = @import("core");
const data = @import("data");
const render3d = @import("render3d");
const effects_mod = @import("effects.zig");
const options = @import("walk_test_options");

const testing = std.testing;
const Effect = effects_mod.Effect;
const dt = core.time.Timestep.fromHz(60).elapsedAt(1).toSecondsF32();

fn engineInit() !*app.Engine {
    const engine = try app.Engine.init(testing.allocator, .{ .headless = true, .workers = 0, .content_dir = options.generated, .content = &.{
        .{ .base_dir = std.fs.path.dirname(options.core_package).?, .file = std.fs.path.basename(options.core_package), .root = "core-assets" },
        .{ .base_dir = std.fs.path.dirname(options.package).?, .file = std.fs.path.basename(options.package), .root = "sandbox3d-assets" },
    } });
    errdefer engine.deinit();
    return engine;
}

const Rig = struct {
    engine: *app.Engine,
    renderer: render3d.Renderer,
    content: render3d.Content,
    effects: effects_mod.Effects,

    fn init(self: *Rig) !void {
        self.engine = try engineInit();
        errdefer self.engine.deinit();
        self.renderer = try render3d.Renderer.init(testing.allocator, self.engine.gpu, .{ .cull = false });
        errdefer self.renderer.deinit();
        self.content = render3d.Content.init(testing.allocator, &self.renderer, &self.engine.assets, .default);
        errdefer self.content.deinit();
        try self.effects.init(testing.allocator, &self.renderer, &self.content);
    }

    fn deinit(self: *Rig) void {
        self.effects.deinit();
        self.content.deinit();
        self.renderer.deinit();
        self.engine.deinit();
    }

    fn live(self: *Rig) u32 {
        var total: u32 = 0;
        for (self.effects.handles) |h| total += self.effects.particles.liveCount(h.?).?;
        return total;
    }
};

test "effects: every record decodes and the corner makes all five" {
    if (comptime !options.available) return error.SkipZigTest;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    for (std.enums.values(Effect)) |effect| {
        const record = rig.engine.store.lookup(effect.id()).?;
        _ = try asset.particle_emitter.decode(record.fields);
        try testing.expect(rig.effects.handles[@intFromEnum(effect)] != null);
    }
}

test "effects: the fountain is pinned at its tick and the corner holds about 11,000 particles" {
    if (comptime !options.available) return error.SkipZigTest;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    // As `app` steps: its first tick is 1.
    for (1..effects_mod.pin_tick + 1) |tick| rig.effects.step(rig.engine, tick, dt, null);
    try testing.expectEqual(@as(?u64, 0xc5f2d56ba1124b5d), rig.effects.pinned);
    const total = rig.live();
    try testing.expect(total >= 10_000 and total <= 11_500);
}

test "effects: unknown modes are said and leave the corner out" {
    try testing.expectEqual(effects_mod.Mode.on, effects_mod.Mode.parse(null));
    try testing.expectEqual(effects_mod.Mode.off, effects_mod.Mode.parse("off"));
    try testing.expectEqual(effects_mod.Mode.off, effects_mod.Mode.parse("sometimes"));
}

test "effects: embers changes the torch's rate and colour with no code, and the handle is kept" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const flame = rig.effects.handles[@intFromEnum(Effect.torch_flame)].?;
    for (0..60) |tick| rig.effects.step(rig.engine, tick, dt, null);
    const before = rig.effects.particles.liveCount(flame).?;

    const bytes = try rig.engine.os.readFile(gpa, options.embers_package, 16 * 1024 * 1024);
    defer gpa.free(bytes);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    const handle = try rig.engine.store.add(gpa, "embers:content", bytes, &rig.engine.schemas, &diags);
    try rig.engine.assets.mount(gpa, handle, options.generated);
    try rig.content.contentChanged();
    rig.effects.contentChanged();

    const record = try asset.particle_emitter.decode(rig.engine.store.lookup(Effect.torch_flame.id()).?.fields);
    try testing.expectEqual(@as(f32, 180), record.rate);
    const material = rig.content.acquireMaterial(core.ContentId.fromString("sandbox3d:materials.flame")) catch unreachable;
    defer rig.content.releaseMaterial(material);
    try testing.expectEqual([3]f32{ 0.3, 1, 0.4 }, rig.renderer.materials.getConst(material).?.desc.emissive);
    // The same handle, its particles kept, now spawning twice as fast.
    try testing.expectEqual(@as(?u32, before), rig.effects.particles.liveCount(flame));
    for (60..120) |tick| rig.effects.step(rig.engine, tick, dt, null);
    try testing.expect(rig.effects.particles.liveCount(flame).? > before + before / 2);
}
