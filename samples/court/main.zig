//! M26's playable 3D sample: a court, three beacons, a gate and a warden (playable3d.md).
//! The build grants no RHI or ABI import; rendering uses the same public renderers a game has.
//!
//! The frame draws, mixes sound and describes UI; everything that decides the outcome runs in
//! fixed ticks from one `Intent`. A menu's choice reaches the game as that intent's action.
//!
//! Host bootstrap: `--msaa=1|4`, `--shadows=on|off`, and for scripted runs
//! `FOUNDRY_COURT_FRAMES`, `FOUNDRY_COURT_PLAY=win|caught|fell`, `FOUNDRY_COURT_WORKERS`,
//! `FOUNDRY_COURT_SAVE_DIR` (a disposable preferences root) and `FOUNDRY_COURT_OVERLAY=1`
//! (the debug overlay, also F1).
const std = @import("std");
const app = @import("app");
const asset = @import("asset");
const audio = @import("audio");
const core = @import("core");
const data = @import("data");
// The in-process debug overlay (ADR-0025): a game opts in by importing it.
const debug = @import("debug");
const platform = @import("platform");
const render2d = @import("render2d");
const render3d = @import("render3d");
const ui = @import("ui");
const walk_mod = @import("walk.zig");
const game_mod = @import("game.zig");
const menus_mod = @import("menus.zig");
const hud = @import("hud.zig");
const scripted = @import("scripted.zig");
const sounds_mod = @import("sounds.zig");
const Preferences = @import("prefs.zig").Preferences;
const Text = @import("text.zig").Text;
const Settings = @import("settings.zig").Settings;
const log = core.log.scoped(.court);
pub const std_options = app.std_options;

const theme_id = "court:ui.theme";

const Options = struct {
    sample_count: u32 = 4,
    shadows: bool = true,
    fn parse(self: *Options, arg: []const u8) bool {
        if (std.mem.eql(u8, arg, "--msaa=1")) self.sample_count = 1 else if (std.mem.eql(u8, arg, "--msaa=4")) self.sample_count = 4 else if (std.mem.eql(u8, arg, "--shadows=on")) self.shadows = true else if (std.mem.eql(u8, arg, "--shadows=off")) self.shadows = false else return false;
        return true;
    }
};

/// The 2D half of the frame: the overlay renderer, the UI kernel, the theme and the font.
const Screens = struct {
    gpa: std.mem.Allocator,
    overlay: render2d.Renderer,
    ctx: ui.Context,
    theme: ?app.UiTheme = null,
    font_asset: asset.AssetHandle = .none,
    /// The debug overlay, in a kernel of its own: its look is not the court's theme.
    panels: *debug.Overlay,
    panels_ctx: ui.Context,
    panels_open: bool = false,

    fn init(gpa: std.mem.Allocator, engine: *app.Engine) !Screens {
        var overlay = try render2d.Renderer.init(gpa, engine.gpu, .{ .jobs = engine.jobs() });
        errdefer overlay.deinit();
        const panels = try debug.Overlay.init(gpa, .{});
        return .{
            .gpa = gpa,
            .overlay = overlay,
            .ctx = .init(gpa, fallbackStyle(.{ .font = placeholderFont() })),
            .panels = panels,
            .panels_ctx = .init(gpa, panelStyle(.{ .font = placeholderFont() })),
        };
    }

    /// After `self` has its final address: the texture loader borrows the renderer.
    fn load(self: *Screens, engine: *app.Engine) !void {
        try engine.assets.registerLoader(self.gpa, render2d.textureLoader(&self.overlay));
        self.font_asset = engine.assets.acquire(self.gpa, core.ContentId.fromString("foundry:fonts.debug")) catch |err| blk: {
            log.warn("the fallback font is unavailable ({t})", .{err});
            break :blk .none;
        };
        var diags: data.Diagnostics = .init(self.gpa, .default);
        defer diags.deinit(self.gpa);
        self.theme = app.resolveUiTheme(self.gpa, &engine.store, &engine.assets, &self.overlay, core.ContentId.fromString(theme_id), &diags) catch |err| blk: {
            log.warn("the ui theme could not be resolved ({t})", .{err});
            break :blk null;
        };
        for (diags.items.items) |d| log.warn("{s}", .{d.message});
        if (self.theme != null) log.info("the screens are drawn from {s}", .{theme_id});
    }

    fn deinit(self: *Screens, engine: *app.Engine) void {
        self.ctx.skin = null;
        if (self.theme) |*theme| theme.deinit(&engine.assets);
        self.theme = null;
        if (!self.font_asset.isNone()) engine.assets.release(self.font_asset);
        _ = engine.assets.unregisterLoader(self.gpa, asset.schemas.texture.id);
        self.panels.deinit();
        self.panels_ctx.deinit();
        self.ctx.deinit();
        self.overlay.deinit();
    }

    /// The font the frame is measured and drawn with: the theme's, or the plain fallback.
    fn font(self: *Screens, engine: *app.Engine) app.UiFont {
        if (self.theme) |*theme| return theme.font;
        var fallback = placeholderFont();
        if (engine.assets.payloadOf(self.font_asset)) |payload| {
            if (self.overlay.textureRegion(payload.asHandle(render2d.TextureHandle))) |glyphs| fallback.glyphs = glyphs;
        }
        return .{ .font = fallback };
    }

    /// The engine's plain font, which the debug overlay always uses.
    fn plainFont(self: *Screens, engine: *app.Engine) app.UiFont {
        var plain = placeholderFont();
        if (engine.assets.payloadOf(self.font_asset)) |payload| {
            if (self.overlay.textureRegion(payload.asHandle(render2d.TextureHandle))) |glyphs| plain.glyphs = glyphs;
        }
        return .{ .font = plain };
    }

    /// The debug overlay's frame, over the court's own. The renderers and the mixer are the
    /// game's, so the game hands them over.
    fn describePanels(self: *Screens, engine: *app.Engine, size: core.math.Vec2, renderer: *const render3d.Renderer, mixer: ?*const audio.Mixer) !void {
        if (!self.panels_open) return;
        self.panels_ctx.style = panelStyle(self.plainFont(engine));
        self.panels_ctx.begin(.{
            .keys = engine.input,
            .pointer = if (engine.input.mouse.captured) .init(-1, -1) else engine.input.mouse.position,
            .wheel = engine.input.mouse.wheel,
            .frame = engine.frame_index,
        }, .init(0, 0, size.x, size.y));
        defer self.panels_ctx.end();
        try self.panels.describe(&self.panels_ctx, engine, .{ .renderer = &self.overlay, .world3d = renderer, .mixer = mixer });
    }

    /// Describes the HUD or the menu for this frame and reports what the pointer did.
    fn describe(self: *Screens, engine: *app.Engine, view: hud.View, options: *menus_mod.Options) !hud.Result {
        self.ctx.style = if (self.theme) |*theme| theme.style else fallbackStyle(self.font(engine));
        self.ctx.skin = if (self.theme) |*theme| theme.skin else null;
        self.ctx.begin(.{
            .keys = engine.input,
            // A captured pointer has no position (§4.4): the kernel is given one outside
            // every row.
            .pointer = if (engine.input.mouse.captured) .init(-1, -1) else engine.input.mouse.position,
            .wheel = engine.input.mouse.wheel,
            .frame = engine.frame_index,
        }, .init(0, 0, view.size.x, view.size.y));
        defer self.ctx.end();
        return hud.describe(&self.ctx, view, options);
    }

    fn draw(self: *Screens, engine: *app.Engine, logical: platform.Size, scale: f32) !void {
        try self.overlay.begin(.{
            .camera = .{ .viewport = .init(0, 0, @floatFromInt(logical.width), @floatFromInt(logical.height)) },
            .pixel_scale = scale,
        });
        try self.overlay.setView(.screen);
        const options: app.UiDrawOptions = if (self.theme) |*theme| theme.drawOptions(0) else .{};
        try app.drawUi(&self.ctx.list, &self.overlay, self.font(engine), .screen, options);
        if (self.panels_open) try app.drawUi(&self.panels_ctx.list, &self.overlay, self.plainFont(engine), .screen, .{ .layer = 1 });
    }
};

/// The glyph layout of `foundry:fonts.debug`, before its texture is resident.
fn placeholderFont() render2d.BitmapFont {
    return .{
        .glyphs = .{ .texture = .none, .uv = .{}, .size_px = .{} },
        .cell = .{ .width = 8, .height = 8 },
        .columns = 16,
        .glyph_count = 95,
    };
}

/// What the screens look like when `court:ui.theme` cannot be used (§6.1): plain, legible,
/// and the same layout. The theme states the real look; this is not a second one.
fn fallbackStyle(font: app.UiFont) ui.Style {
    return .{
        .font = font.metrics(),
        .text_scale = 2,
        .line_height = 34,
        .padding = .init(14, 8),
        .spacing = 6,
        .separator_thickness = 1,
        .text = .linear(1, 1, 1, 1),
        .text_dim = .linear(0.6, 0.6, 0.6, 1),
        .surface = .linear(0, 0, 0, 0.85),
        .control = .linear(0.1, 0.1, 0.1, 1),
        .control_hot = .linear(0.2, 0.2, 0.2, 1),
        .control_active = .linear(0.8, 0.8, 0.8, 1),
        .accent = .linear(0.8, 0.8, 0.8, 1),
    };
}

/// The debug overlay's look: small and plain, as the other samples have it (ADR-0024).
fn panelStyle(font: app.UiFont) ui.Style {
    return .{
        .font = font.metrics(),
        .text_scale = 1,
        .line_height = 14,
        .padding = .init(6, 4),
        .spacing = 3,
        .separator_thickness = 1,
        .text = .linear(0.5, 0.83, 1, 1),
        .text_dim = .linear(0.19, 0.3, 0.4, 1),
        .surface = .linear(0, 0, 0, 0.67),
        .control = .linear(0.013, 0.021, 0.038, 0.86),
        .control_hot = .linear(0.032, 0.061, 0.115, 0.92),
        .control_active = .linear(0.08, 0.155, 0.283, 1),
        .accent = .linear(0.188, 0.578, 1, 1),
    };
}

/// A person's menu keys: the arrows, Enter and Escape, as edges.
fn menuKeys(input: platform.InputSnapshot) menus_mod.Keys {
    return .{
        .up = input.wasPressed(.up),
        .down = input.wasPressed(.down),
        .left = input.wasPressed(.left),
        .right = input.wasPressed(.right),
        .accept = input.wasPressed(.enter) or input.wasPressed(.kp_enter),
        .back = input.wasPressed(.escape),
    };
}

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

    // A scripted play-through is a proof: an unknown name, a wrong ending or a run that
    // does not finish fails the process instead of leaving a window walking nowhere.
    const play_mode: ?scripted.ScriptKind = if (os.envVar("FOUNDRY_COURT_PLAY")) |val|
        scripted.ScriptKind.parse(val) orelse {
            log.err("unknown FOUNDRY_COURT_PLAY '{s}' (expected win|caught|fell)", .{val});
            return error.InvalidPlayScript;
        }
    else
        null;
    const frame_budget: ?u64 = if (os.envVar("FOUNDRY_COURT_FRAMES")) |s| blk: {
        const n = std.fmt.parseInt(u64, s, 10) catch return error.InvalidFrameLimit;
        if (n == 0) return error.InvalidFrameLimit;
        break :blk n;
    } else null;
    // Headless and budgeted runs leave the player's file alone (§8); so does a script.
    var prefs = try Preferences.open(gpa, os, headless, frame_budget != null or play_mode != null, os.envVar("FOUNDRY_COURT_SAVE_DIR"));
    defer prefs.deinit(gpa);

    var engine = try app.Engine.init(gpa, .{
        .env = env,
        .app_name = "foundry-court",
        .log_level = .info,
        .headless = headless,
        .workers = workers,
        .tick_rate_hz = 60,
        .profiler = true,
        .window = .{ .title = "court", .logical_width = Preferences.fallback_width, .logical_height = Preferences.fallback_height, .surface = app.window_surface },
        .content_dir = content_dir,
        .content = packages,
    });
    defer engine.deinit();
    const record = engine.store.lookup(core.ContentId.fromString("court:config.main")) orelse return error.MissingConfig;
    const settings = Settings.read(record) catch |err| {
        log.warn("invalid court:config.main; court cannot start ({t})", .{err});
        return err;
    };
    prefs.resolve(&engine.store);
    try engine.setWindowTitle(settings.title);
    if (!headless) engine.setWindowSize(.{ .width = prefs.width.value, .height = prefs.height.value }) catch |err| {
        log.info("the window manager kept its own size ({t})", .{err});
    };
    var renderer = try render3d.Renderer.init(gpa, engine.gpu, .{
        .jobs = engine.jobs(),
        .sample_count = options.sample_count,
        .shadow_size = if (options.shadows) 2048 else 0,
    });
    defer renderer.deinit();
    var screens = try Screens.init(gpa, engine);
    defer screens.deinit(engine);
    try screens.load(engine);
    screens.panels_open = engine.os.envVar("FOUNDRY_COURT_OVERLAY") != null;

    // The mixer is the game's (audio.md §7). No device is a configuration, not a fault.
    const mixer: ?*audio.Mixer = audio.Mixer.init(gpa, engine.platform, &engine.assets, .{}) catch |err| blk: {
        log.warn("no audio device ({t}); the court is silent", .{err});
        break :blk null;
    };
    // audio.md's three-call teardown: voices give their assets back, then the loader goes.
    defer if (mixer) |m| {
        m.shutdown();
        _ = engine.assets.unregisterLoader(gpa, asset.schemas.sound.id);
        m.deinit();
    };
    if (mixer) |m| {
        try engine.assets.registerLoader(gpa, m.soundLoader());
        m.setMasterGain(prefs.volume.value);
    }
    var sounds: sounds_mod.Sounds = .{ .mixer = mixer, .set = sounds_mod.SoundSet.find(&engine.store) };

    var content = render3d.Content.init(gpa, &renderer, &engine.assets, .default);
    defer content.deinit();
    try engine.assets.registerLoader(gpa, asset.collisionMeshLoader());
    const level = try content.acquireModel(settings.level);
    defer content.releaseModel(level);
    var game = game_mod.Game.init(gpa);
    defer game.deinit(&engine.assets, &content);
    game.refresh(&engine.store, &engine.assets, &content, engine.step_delta.toSecondsF32());
    if (game.walk.character.isNone() or game.walk.collisions[0].body.isNone()) return error.MissingLevelCollision;
    if (sounds.set) |set| {
        game.stride = set.step_distance;
        game.warden_stride = set.warden_step_distance;
    }
    const text = Text.read(&engine.store);
    const goal_ticks: u64 = @intFromFloat(@round(settings.goal_seconds / engine.step_delta.toSecondsF32()));

    var script_driver = if (play_mode) |m| scripted.ScriptDriver.init(m) else null;
    var menus: menus_mod.Menus = .{};
    var chosen = prefs.options();
    var pending: walk_mod.Pending = .{};
    var quit_by_menu = false;
    var captured_for: ?game_mod.Phase = null;
    var skin_dropped: u32 = 0;

    log.info("WASD walk, Space jump, E light a beacon, mouse or arrows look, Escape pause; menus: arrows, Enter, Escape or the pointer", .{});
    // Headless with neither a budget nor a script would run for ever.
    const limit: ?u64 = frame_budget orelse if (headless and play_mode == null) @as(u64, 120) else null;
    if (headless) engine.platform.setClockStep(engine.step_delta);
    var skipped: u64 = 0;
    var pace_next: u64 = 0;
    while (!engine.shouldQuit()) {
        const started = if (!headless) engine.os.monotonicNanos() else 0;
        engine.beginFrame();
        var lost_focus = false;
        while (engine.nextEvent()) |event| switch (event) {
            .window_resized => |resized| prefs.noteResize(resized.logical_size),
            .window_focus_lost => lost_focus = true,
            else => {},
        };

        const info = engine.windowInfo();
        const logical: platform.Size = if (info) |i| i.logical_size else .{ .width = prefs.width.value, .height = prefs.height.value };

        // 1. What the hands did: a person's devices, or the script's.
        var frame: scripted.Frame = if (script_driver) |*d|
            d.next(&game)
        else
            .{ .intent = walk_mod.inputIntent(engine.input, false), .keys = menuKeys(engine.input) };
        if (script_driver == null) {
            // Sensitivity and invert are the player's (§8); the arrows stay as they are.
            frame.intent.look_dx *= chosen.sensitivity;
            frame.intent.look_dy *= if (chosen.invert) -chosen.sensitivity else chosen.sensitivity;
            if (chosen.invert) frame.intent.pitch = -frame.intent.pitch;
        }

        // 2. The screen, described from last frame's menu state, and what the pointer did.
        const motion = engine.input.mouse.motion;
        const shown = try screens.describe(engine, .{
            .phase = game.phase,
            .menus = &menus,
            .text = &text,
            .lit = game.litCount(),
            .beacons = game.beacon_count,
            .aimed = game.aimed != null,
            .gate_open = if (game.gate) |*g| g.opening else false,
            .has_gate = game.gate != null,
            .show_goal = game.tick < goal_ticks,
            .pointer_moved = motion.x != 0 or motion.y != 0,
            .size = .init(@floatFromInt(logical.width), @floatFromInt(logical.height)),
        }, &chosen);

        // The debug overlay declares no key of its own; F1 is the court's choice for it.
        if (engine.input.wasPressed(.f1)) screens.panels_open = !screens.panels_open;
        try screens.describePanels(engine, .init(@floatFromInt(logical.width), @floatFromInt(logical.height)), &renderer, mixer);

        // 3. The menu's answer. Only a phase change travels to the tick.
        var command = menus.update(game.phase, frame.keys, shown.hovered, shown.clicked, &chosen);
        // Losing the window pauses a game in play: the capture is gone, and is asked for
        // again only when the player resumes (§4.2).
        if (lost_focus and game.phase == .playing and command == .none) command = .pause;
        switch (command) {
            .none => {},
            .quit => {
                quit_by_menu = true;
                engine.requestQuit();
            },
            else => sounds.click(),
        }
        if (command == .options_changed or shown.options_changed) {
            prefs.noteOptions(chosen);
            if (mixer) |m| m.setMasterGain(chosen.volume);
        }
        frame.intent.action = command.action();
        pending.feed(frame.intent);

        // 4. The ticks.
        while (engine.nextStep()) |step| {
            const scope = engine.beginScope("character");
            defer scope.end();
            try game.step(pending.take(), step.delta.toSecondsF32());
            sounds.onEvents(&game);
        }

        // 5. Captured while playing, released in every menu (§4.4). Asked once per change.
        if (captured_for != game.phase) {
            captured_for = game.phase;
            capture(engine, game.phase == .playing);
        }

        const extent: render3d.Extent2D = if (info) |i| .{ .width = i.pixel_size.width, .height = i.pixel_size.height } else .{ .width = logical.width, .height = logical.height };
        const drew = draw(engine, &renderer, &content, &screens, level, &game, settings, extent, logical, if (info) |i| i.scale else 1) catch |err| blk: {
            if (!app.Engine.frameSkippable(err)) return err;
            break :blk false;
        };
        skin_dropped += renderer.frameStats().skin_budget_dropped;
        sounds.frame(&game);
        // The null device has no thread: a frame's worth of audio is mixed here, so voices
        // end and a long headless run plays every sound it starts.
        if (comptime platform.backend == .null) if (mixer) |m| {
            _ = engine.platform.stepAudio(m.device, 48_000 / 60) catch |err| log.warn("the null device did not step ({t})", .{err});
        };
        prefs.tick(gpa);
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
        if (script_driver) |d| if (d.done) break;
    }
    prefs.flush(gpa);
    sounds.silence();
    const stats = renderer.frameStats();
    const commands_dropped = if (mixer) |m| m.commandsDropped() else 0;
    log.info("stopped after {d} frames ({d} skipped), {d} ticks; {d} draws, {d} lights; phase {s}; feet ({d:.3}, {d:.3}, {d:.3})", .{
        engine.frame_index, skipped, engine.stepper.tick, stats.draws, stats.lights, @tagName(game.phase), game.walk.result.feet.x, game.walk.result.feet.y, game.walk.result.feet.z,
    });
    log.info("sounds: {d} asked for, {d} played, {d} dropped; {d} mixer command(s) and {d} event(s) dropped", .{
        sounds.requested, sounds.played, sounds.dropped, commands_dropped, game.events_dropped,
    });
    if (script_driver) |d| {
        log.info("play '{s}': {d} of {d} step(s) in {d} frames", .{ @tagName(play_mode.?), d.step, d.script.steps.len, d.ticks });
        if (!d.succeeded()) {
            if (d.failure) |why| log.err("play '{s}' failed: {s}", .{ @tagName(play_mode.?), @tagName(why) }) else log.err("play '{s}' stopped before it finished", .{@tagName(play_mode.?)});
            return error.PlayScriptFailed;
        }
        if (d.script.quits and !quit_by_menu) {
            log.err("play '{s}' did not quit through the menu", .{@tagName(play_mode.?)});
            return error.PlayScriptFailed;
        }
        // §10.2: nothing a run asked for was dropped for capacity, and no frame failed.
        if (sounds.dropped != 0 or commands_dropped != 0 or game.events_dropped != 0 or skin_dropped != 0 or skipped != 0) {
            log.err("play '{s}' dropped something: {d} sound(s), {d} mixer command(s), {d} event(s), {d} skinned draw(s), {d} frame(s)", .{
                @tagName(play_mode.?), sounds.dropped, commands_dropped, game.events_dropped, skin_dropped, skipped,
            });
            return error.PlayScriptFailed;
        }
    }
}

fn capture(engine: *app.Engine, want: bool) void {
    if (engine.input.mouse.captured == want) return;
    engine.setPointerCapture(want) catch |err| {
        // Said once per phase change, and only when it matters: releasing cannot fail a
        // player, and headless has no pointer to capture.
        if (want) log.info("pointer capture unavailable ({t}); the arrows still look", .{err});
    };
}

fn draw(engine: *app.Engine, renderer: *render3d.Renderer, content: *render3d.Content, screens: *Screens, level: render3d.ModelHandle, game: *game_mod.Game, settings: Settings, extent: render3d.Extent2D, logical: platform.Size, scale: f32) !bool {
    const dt = engine.step_delta.toSecondsF32();
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
    for (game.beacons[0..game.beacon_count]) |*b| {
        if (b.lit) {
            try renderer.addLight(.{
                .kind = .point,
                .color = b.settings.light_color,
                .intensity = b.settings.light_intensity,
                .range = b.settings.light_range,
                .world = core.math.Mat4.translation(b.lightPosition()),
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
        // A warden whose skeleton or clips do not resolve is left undrawn; it still patrols.
        w.evaluate(content, dt) catch |err| log.debug("warden pose skipped ({t})", .{err});
        try w.draw(content);
    }
    try screens.draw(engine, logical, scale);
    try engine.renderScene(.{}, renderer, &screens.overlay);
    return true;
}

test {
    _ = @import("walk.zig");
    _ = @import("light_settings.zig");
    _ = @import("walk_tests.zig");
    _ = @import("game.zig");
    _ = @import("game_tests.zig");
    _ = @import("menus.zig");
    _ = @import("sounds.zig");
    _ = @import("prefs.zig");
    _ = @import("text.zig");
    _ = @import("hud.zig");
    _ = @import("screen_tests.zig");
}
