//! M26 Step 2: level, light and movement. Outcomes, HUD, audio and menus are later steps.
//! The build grants no RHI or ABI import; rendering uses the same public renderer as a game.
const std = @import("std");
const app = @import("app");
const asset = @import("asset");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const render3d = @import("render3d");
const walk_mod = @import("walk.zig");
const game_mod = @import("game.zig");
const scripted = @import("scripted.zig");
const Settings = @import("settings.zig").Settings;
const log = core.log.scoped(.court);
pub const std_options = app.std_options;

const Options = struct {
    sample_count: u32 = 4,
    shadows: bool = true,
    fn parse(self: *Options, arg: []const u8) bool {
        if (std.mem.eql(u8, arg, "--msaa=1")) self.sample_count = 1 else if (std.mem.eql(u8, arg, "--msaa=4")) self.sample_count = 4 else if (std.mem.eql(u8, arg, "--shadows=on")) self.shadows = true else if (std.mem.eql(u8, arg, "--shadows=off")) self.shadows = false else return false;
        return true;
    }
};

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    var options: Options = .{};
    while (args.next()) |arg| if (!options.parse(arg)) {
        log.warn("usage: court [--msaa=1|4] [--shadows=on|off]", .{});
        std.process.exit(2);
    };
    const env = try app.environment(init.gpa, init);
    defer init.gpa.free(env);
    try run(init.gpa, env, options);
}

fn run(gpa: std.mem.Allocator, env: []const platform.os.EnvVar, options: Options) !void {
    const headless = platform.backend == .null;
    var os = try platform.os.Os.init(gpa, .{ .env = env, .app_name = "foundry-court" });
    defer os.deinit();
    const content_dir = try app.contentDirOf(gpa, os, null);
    defer gpa.free(content_dir);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    // Installed package zero uses the ordinary discovery/resolution path (I3).
    const roots = [_]app.mods.Root{.{ .dir = content_dir, .origin = .installed }};
    var mods = try app.ModSet.init(gpa, os, &roots, .{
        .required = &.{ try data.contentId("foundry:core"), try data.contentId("court:content") },
    }, &diags);
    defer mods.deinit();
    _ = try mods.start(&.{}, &diags);
    for (diags.items.items) |d| log.warn("content: {s}", .{d.message});
    const packages = try mods.contentPackages(gpa);
    defer gpa.free(packages);
    const workers = if (os.envVar("FOUNDRY_COURT_WORKERS")) |s| std.fmt.parseInt(u16, s, 10) catch return error.InvalidWorkers else null;
    var engine = try app.Engine.init(gpa, .{
        .env = env,
        .app_name = "foundry-court",
        .log_level = .info,
        .headless = headless,
        .workers = workers,
        .tick_rate_hz = 60,
        .profiler = true,
        .window = .{ .title = "court", .logical_width = 1280, .logical_height = 720, .surface = app.window_surface },
        .content_dir = content_dir,
        .content = packages,
    });
    defer engine.deinit();
    const record = engine.store.lookup(core.ContentId.fromString("court:config.main")) orelse return error.MissingConfig;
    const settings = Settings.read(record) catch |err| {
        log.warn("invalid court:config.main; court cannot start ({t})", .{err});
        return err;
    };
    try engine.setWindowTitle(settings.title);
    if (!headless) try engine.setWindowSize(.{ .width = settings.width, .height = settings.height });
    var renderer = try render3d.Renderer.init(gpa, engine.gpu, .{
        .jobs = engine.jobs(),
        .sample_count = options.sample_count,
        .shadow_size = if (options.shadows) 2048 else 0,
    });
    defer renderer.deinit();
    var content = render3d.Content.init(gpa, &renderer, &engine.assets, .default);
    defer content.deinit();
    try engine.assets.registerLoader(gpa, asset.collisionMeshLoader());
    const level = try content.acquireModel(settings.level);
    defer content.releaseModel(level);
    var game = game_mod.Game.init(gpa);
    defer game.deinit(&engine.assets, &content);
    game.refresh(&engine.store, &engine.assets, &content, engine.step_delta.toSecondsF32());
    if (game.walk.character.isNone() or game.walk.collisions[0].body.isNone()) return error.MissingLevelCollision;

    const play_mode: ?scripted.ScriptKind = if (os.envVar("FOUNDRY_COURT_PLAY")) |val| blk: {
        if (std.mem.eql(u8, val, "win")) break :blk .win;
        if (std.mem.eql(u8, val, "caught")) break :blk .caught;
        if (std.mem.eql(u8, val, "fell")) break :blk .fell;
        log.warn("unknown FOUNDRY_COURT_PLAY '{s}' (expected win|caught|fell)", .{val});
        break :blk null;
    } else null;
    var script_driver = if (play_mode) |m| scripted.ScriptDriver.init(m) else null;

    // Request once. Focus loss releases it; F4 is the skeleton's explicit re-capture.
    capture(engine, true);
    log.info("WASD walk, Space jump, E use, R restart, captured mouse/arrows look, F4 capture/release, Escape quit", .{});
    var pending: walk_mod.Pending = .{};
    const limit: ?u64 = if (os.envVar("FOUNDRY_COURT_FRAMES")) |s| blk: {
        const n = std.fmt.parseInt(u64, s, 10) catch return error.InvalidFrameLimit;
        if (n == 0) return error.InvalidFrameLimit;
        break :blk n;
    } else if (headless) @as(u64, 120) else null;
    if (headless) engine.platform.setClockStep(engine.step_delta);
    var skipped: u64 = 0;
    var pace_next: u64 = 0;
    while (!engine.shouldQuit()) {
        const started = if (!headless) engine.os.monotonicNanos() else 0;
        engine.beginFrame();
        while (engine.nextEvent()) |_| {}
        if (engine.input.wasPressed(.escape)) engine.requestQuit();
        if (engine.input.wasPressed(.f4)) capture(engine, !engine.input.mouse.captured);
        if (script_driver == null) {
            pending.feed(walk_mod.inputIntent(engine.input, false));
        }
        while (engine.nextStep()) |step| {
            const scope = engine.beginScope("character");
            defer scope.end();
            const intent = if (script_driver) |*d| d.nextIntent(&game, step.delta.toSecondsF32()) else pending.take();
            try game.step(intent, step.delta.toSecondsF32());
        }
        const info = engine.windowInfo();
        const extent: render3d.Extent2D = if (info) |i| .{ .width = i.pixel_size.width, .height = i.pixel_size.height } else .{ .width = settings.width, .height = settings.height };
        const drew = draw(engine, &renderer, &content, level, &game, settings, extent, engine.step_delta.toSecondsF32()) catch |err| blk: {
            if (!app.Engine.frameSkippable(err)) return err;
            break :blk false;
        };
        if (!drew) {
            skipped += 1;
            engine.os.sleep(engine.step_delta);
            pace_next = 0;
        } else if (!headless) {
            const budget: u64 = @intCast(engine.step_delta.ns);
            pace_next = if (pace_next == 0) started + budget else pace_next + budget;
            const now = engine.os.monotonicNanos();
            if (now < pace_next) engine.os.sleep(.fromNanos(@intCast(pace_next - now))) else if (now - pace_next > 250 * core.time.ns_per_ms) pace_next = now;
        }
        engine.endFrame();
        if (limit) |n| if (engine.frame_index >= n) break;
    }
    const stats = renderer.frameStats();
    log.info("stopped after {d} frames ({d} skipped), {d} ticks; {d} draws, {d} lights; phase {s}; feet ({d:.3}, {d:.3}, {d:.3})", .{
        engine.frame_index, skipped, engine.stepper.tick, stats.draws, stats.lights, @tagName(game.phase), game.walk.result.feet.x, game.walk.result.feet.y, game.walk.result.feet.z,
    });
}

fn capture(engine: *app.Engine, want: bool) void {
    engine.setPointerCapture(want) catch |err| {
        log.warn("pointer capture unavailable ({t}); arrows still look", .{err});
    };
}

fn draw(engine: *app.Engine, renderer: *render3d.Renderer, content: *render3d.Content, level: render3d.ModelHandle, game: *game_mod.Game, settings: Settings, extent: render3d.Extent2D, dt: f32) !bool {
    if (extent.isEmpty()) return false;
    try renderer.begin(.{
        .camera = .{ .position = game.walk.eye(), .rotation = game.walk.rotation(), .vertical_fov = std.math.pi / 3.2, .near = 0.1, .far = 80 },
        .target_size = extent,
        .clear_color = settings.clear,
        .ambient = settings.lighting.ambient,
        .exposure_ev100 = settings.lighting.exposure_ev100,
        .shadow_distance = 20,
    });
    for (settings.lighting.lights[0..settings.lighting.len]) |light| try renderer.addLight(light);
    for (game.beacons[0..game.beacon_count]) |b| {
        if (b.lit) {
            try renderer.addLight(.{
                .kind = .point,
                .color = b.settings.light_color,
                .intensity = b.settings.light_intensity,
                .range = b.settings.light_range,
                .world = core.math.Mat4.translation(b.settings.position.add(.init(0, 1.0, 0))),
            });
        }
    }
    try content.drawModel(.{ .model = level, .world = .identity });
    for (game.beacons[0..game.beacon_count]) |b| {
        if (!b.model.isNone()) {
            try content.drawModel(.{ .model = b.model, .world = core.math.Mat4.trs(b.settings.position, .identity, .one) });
        }
    }
    if (game.gate) |g| {
        if (!g.model.isNone()) {
            try content.drawModel(.{ .model = g.model, .world = core.math.Mat4.trs(g.current_pos, .identity, .one) });
        }
    }
    if (game.warden) |*w| {
        w.evaluate(content, dt) catch {};
        try w.draw(content);
    }
    try engine.renderScene(.{}, renderer, null);
    return true;
}

test {
    _ = @import("walk.zig");
    _ = @import("light_settings.zig");
    _ = @import("walk_tests.zig");
    _ = @import("game.zig");
    _ = @import("game_tests.zig");
}
