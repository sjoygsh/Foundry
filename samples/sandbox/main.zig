//! `samples/sandbox` — the smallest thing that exercises the engine.
//!
//! It opens a window, logs input, runs the fixed-timestep loop, draws thousands of sprites
//! under a camera that pans, zooms and picks, survives being resized, and exits cleanly.
//!
//! The rendering is deliberately run on **both** backends rather than only where it is
//! visible. Under `-Drhi=null` the same command stream goes through the validation backend,
//! so the headless run is a continuous check that what Metal accepts also satisfies the ten
//! rules of `docs/design/rhi.md` §11 — which is exactly the cross-check M1 exists to
//! establish.
//!
//! It is also the reference for what a game's entry point looks like. A game lives in its
//! own repository and consumes Foundry as a dependency (ADR-0017), but its `main` is this
//! one: marshal the environment, configure, initialise, loop, tear down.
//!
//! **A sample is not a game.** When one starts wanting features rather than demonstrating
//! them, it has outgrown this repository.

const std = @import("std");
const builtin = @import("builtin");

const app = @import("app");
const core = @import("core");
const asset = @import("asset");
const platform = @import("platform");
const render2d = @import("render2d");
const rhi = @import("rhi");

/// Routes Foundry's logging through the engine's sink. One line, in the root source file.
pub const std_options = app.std_options;

const log = core.log.scoped(.sandbox);

/// The null platform backend has no window and no way to deliver a quit event, so a
/// headless run bounds itself instead of hanging forever. Overridable so that a windowed
/// run can also be bounded, which is what makes this usable as an automated check.
const default_headless_frames: u64 = 600;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Zig 0.16 hands the environment to the entry point rather than exposing it
    // ambiently, and Foundry keeps it that way on purpose: configuration read from the
    // air is a hidden input (I9).
    const env = try app.environment(gpa, init);
    defer gpa.free(env);

    // The backend is a compile-time property of the build, so the sample can ask what it
    // was built against rather than discovering it by failing.
    const headless = platform.backend == .null;

    var engine = try app.Engine.init(gpa, .{
        .env = env,
        .app_name = "foundry-sandbox",
        .log_level = .debug,
        .headless = headless,
        .tick_rate_hz = 60,
        .window = .{
            .title = "Foundry Sandbox",
            .logical_width = 1280,
            .logical_height = 720,
            .surface = wanted_surface,
        },
    });
    defer engine.deinit();

    // The renderer and its sprites, created once and torn down explicitly. Unlike M1's
    // quad, this *does* have a teardown: `Renderer.deinit` idles the device first, which
    // is what `rhi.waitIdle` was added for.
    var field = try SpriteField.init(gpa, engine.gpu, spriteCount(engine));
    defer field.deinit();
    field.pick_every = everyFrames(engine, "FOUNDRY_SANDBOX_PICK_EVERY");

    const frame_limit = frameLimit(engine, headless);

    if (headless) {
        log.info("headless build ({t} backend): running {d} frames", .{ platform.backend, frame_limit.? });
    } else {
        const info = engine.windowInfo().?;
        log.info("window: {d}x{d} points, {d}x{d} pixels, scale {d:.2}", .{
            info.logical_size.width, info.logical_size.height,
            info.pixel_size.width,   info.pixel_size.height,
            info.scale,
        });
        const caps = engine.gpu.capabilities();
        log.info("gpu: '{t}' backend, surface {t}, {d} bind groups, {d} inline bytes", .{
            rhi.backend, caps.surface_format, caps.max_bind_groups, caps.max_inline_constant_bytes,
        });
        if (engine.nativeSurface()) |surface| {
            if (!surface.isNone()) {
                // The seam: `platform` produced it, `rhi` consumed it, and neither knows
                // what the other's library is.
                log.info("native surface ready: {t}", .{surface.kind});
            } else {
                log.info("no native surface; the clear goes to an offscreen target", .{});
            }
        }
        log.info("WASD or arrows pan; shift pans faster; drag with right or middle", .{});
        log.info("wheel zooms about the cursor; left-click picks; C recentres", .{});
        log.info("R resizes the window; escape or the close button quits", .{});
    }

    var reported_tick: u64 = 0;
    var size_index: usize = 0;
    const auto_resize_every = everyFrames(engine, "FOUNDRY_SANDBOX_RESIZE_EVERY");

    while (!engine.shouldQuit()) {
        engine.beginFrame();

        while (engine.nextEvent()) |ev| report(ev);

        while (engine.nextStep()) |step| {
            // The only place simulation happens. It reads `step.input`, never the device.
            if (step.input.wasPressed(.escape)) engine.requestQuit();

            // Once per second of *simulation* time, not wall-clock time.
            if (step.tick - reported_tick >= 60) {
                reported_tick = step.tick;
                log.debug("tick {d}, frame {d}, sim {d}ms, alpha {d:.2}", .{
                    step.tick,
                    engine.frame_index,
                    step.elapsed.toMillis(),
                    engine.alpha(),
                });
            }
        }

        // Resizing, deliberately **outside** the step loop: which shape a window is is a
        // presentation concern, not simulation, and a simulation step that resized a window
        // would be reaching outside the world it is meant to be computing. It reads the
        // frame's input snapshot, which is the same value every step of this frame saw, so
        // it cannot disagree with them (I9).
        if (!headless) {
            const advance = engine.input.wasPressed(.r) or blk: {
                const every = auto_resize_every orelse break :blk false;
                break :blk engine.frame_index > 0 and engine.frame_index % every == 0;
            };
            if (advance) {
                size_index = (size_index + 1) % size_cycle.len;
                requestResize(engine, size_cycle[size_index]);
            }
        }

        // Rendering, in two halves that are deliberately different jobs. The game builds
        // a draw list; the engine owns the frame and the pass. The sprites' motion comes
        // from simulated time rather than `engine.alpha()`; interpolation arrives with
        // M4's entities, the first thing with two states to interpolate between.
        const seconds = @as(f32, @floatFromInt(engine.elapsed().toMillis())) / 1000.0;
        field.control(engine, seconds);
        try field.submit(engine, seconds);

        engine.renderFrame(.{ .label = "sprites", .clear = clearColor(engine) }, &field.renderer) catch |err| switch (err) {
            // No drawable this frame: minimised, occluded, or all of them still in flight.
            // Transient, so the frame is skipped rather than treated as fatal. The RHI has
            // a single error for "the swapchain gave us nothing", which is a known gap
            // recorded in `PROJECT_STATE.md` rather than papered over here.
            error.SurfaceLost => {},
            else => {
                log.err("frame {d} failed: {t}", .{ engine.frame_index, err });
                engine.requestQuit();
            },
        };

        engine.endFrame();

        // Once a second of wall-clock frames, report what the batcher actually did. A
        // batch count you cannot see is a batch count you cannot tune, which is why M2's
        // roadmap entry asks for statistics at all.
        if (engine.frame_index % 120 == 0) {
            const stats = field.renderer.frameStats();
            log.debug("frame {d}: {d} sprites ({d} glyphs), {d} batches, {d} draw calls, {d} KiB of vertices, {d:.1}ms/frame, zoom {d:.2}", .{
                engine.frame_index,
                stats.sprites,
                stats.glyphs,
                stats.batches,
                stats.draw_calls,
                stats.vertex_bytes / 1024,
                engine.frameDelta().toSecondsF32() * 1000,
                field.camera.zoom,
            });
        }

        // A windowed Metal build is paced by the display: the layer has vsync enabled, so
        // acquiring the next drawable blocks. The null backend has no swapchain to wait on
        // and would otherwise spin as fast as the CPU allows, so that path keeps the crude
        // yield. Still deliberately not inside `Engine` — pacing is renderer policy.
        if (!headless and rhi.backend == .null) engine.os.sleep(.fromMillis(2));

        if (frame_limit) |limit| {
            if (engine.frame_index >= limit) break;
        }
    }

    log.info("clean exit after {d} frames, {d} ticks, {d}ms simulated", .{
        engine.frame_index,
        engine.stepper.tick,
        engine.elapsed().toMillis(),
    });
}

/// The sprite sheet the sandbox draws with, embedded rather than loaded from disk.
///
/// Embedding, not `asset.loadImage`: finding an asset at runtime needs the content system
/// to answer where assets live and what they are called, and that is M3's question
/// (CLAUDE.md §9). Decoding is the part M2 owes, and this exercises it in the real
/// application rather than only in a test.
const sprite_sheet_png = @embedFile("assets/sprites.png");

/// The sandbox's font: 95 glyphs on a 16-by-6 grid of 8-pixel cells, ASCII 32 to 126.
///
/// **Ours, drawn as ASCII art and generated by `scripts/make-sandbox-font.py`** — which is
/// in the repository so the glyphs have a source rather than only a PNG. No third-party
/// asset and so no licence entry, which is the cheapest way to satisfy the permissive-only
/// policy (ADR-0016).
///
/// `render2d` ships no glyphs (I5): a font is an asset the game supplies. The M6 debug
/// overlay will need one too, and the answer to where it comes from has to be "the same
/// place this one does" (I3, I4).
const font_png = @embedFile("assets/font.png");

/// A field of sprites, which is the thing M2 exists to make possible.
///
/// Every sprite's parameters come from one seeded generator run once at startup, so the
/// same build draws the same field every time (I9). The animation is a pure function of
/// simulated time, so it is reproducible too.
///
/// The camera lives here rather than in `render2d` because **which key pans is input
/// policy, and policy belongs to the game.** `render2d` owns the camera *maths* — the
/// projection, `screenToWorld`, `panByScreen`, `zoomAround` — and could not own the
/// bindings even if that were wanted, because it does not depend on `platform` and the
/// build graph would refuse the import (I7).
const SpriteField = struct {
    gpa: std.mem.Allocator,
    renderer: render2d.Renderer,
    /// Everything the sample draws lives in one atlas, which is the whole point of having
    /// one: the batcher breaks a batch on a texture change, and after packing there are no
    /// texture changes left to break on. Sprites, glyphs and the selection outline are one
    /// draw call between them.
    atlas: render2d.AtlasHandle,
    /// The 4x4 sprite sheet, as a region of the atlas. Cells come from `Region.sub`, which
    /// cuts in the *region's* pixel space — so this code is identical whether the sheet is
    /// packed or standalone.
    sheet: render2d.Region,
    /// The interior of an 8-pixel white patch, built in memory rather than loaded.
    /// Stretched into thin quads it draws the selection outline.
    ///
    /// The interior, not the whole patch, and that is the atlas lesson worth having: UVs
    /// interpolate to a region's edges, and in an atlas the texel past an edge belongs to
    /// somebody else. Addressing the middle four pixels of an eight-pixel patch means a
    /// sample that strays lands on more white.
    blank: render2d.Region,
    font: render2d.BitmapFont,
    seeds: []Seed,

    /// Driven by input, so it is state rather than something recomputed per frame.
    camera: render2d.Camera2D,
    /// Which sprite was last clicked, by index into `seeds`. Presentation only: nothing
    /// in the simulation reads it.
    selected: ?usize = null,
    /// Pick at the window's centre every N frames, or null to only pick on a click.
    /// Same rationale as `FOUNDRY_SANDBOX_RESIZE_EVERY`: a windowed path that cannot be
    /// scripted is a path that only gets checked when someone remembers to check it.
    pick_every: ?u64 = null,

    /// What distinguishes one sprite from another, decided once.
    const Seed = struct {
        home: core.math.Vec2,
        radius: f32,
        speed: f32,
        phase: f32,
        size: f32,
        spin: f32,
        cell: u8,
        tint: render2d.Color,
        blend: render2d.BlendMode,
    };

    /// The sheet is a 4x4 grid, so a cell is a quarter of the sheet in each axis.
    const grid: u32 = 4;

    /// Big enough for everything the sample packs, and no bigger. Its fill is logged at
    /// startup, which is the number that says whether that is still true.
    const atlas_size: render2d.Extent2D = .{ .width = 512, .height = 512 };

    /// Screen points. The HUD is placed in the same units the mouse is reported in, which
    /// is what the screen view buys.
    const hud_margin: f32 = 12;
    const hud_padding: f32 = 8;

    /// Zoom limits, in pixels per world unit. Policy, and therefore the sample's: the
    /// camera itself refuses only zooms that are not numbers.
    const min_zoom: f32 = 0.05;
    const max_zoom: f32 = 24;

    /// Keyboard pan speed in **screen points per second**, so it feels the same whatever
    /// the zoom. Panning in world units per second crawls when zoomed out.
    const pan_speed: f32 = 700;
    const fast_pan_speed: f32 = 2400;

    fn init(gpa: std.mem.Allocator, device: *rhi.Device, count: u32) !SpriteField {
        var renderer = try render2d.Renderer.init(gpa, device, .{
            .frames_in_flight = 2,
        });
        errdefer renderer.deinit();

        const atlas = try renderer.createAtlas(atlas_size, .{
            .label = "sandbox atlas",
            // Nearest, so scaling up shows the sheet's pixels rather than a blur. The
            // default, spelled out because it is the interesting choice. It applies to the
            // whole atlas, which is a real constraint: two images needing different
            // filtering cannot share one.
            .filter = .nearest,
        });
        errdefer renderer.destroyAtlas(atlas);

        // The engine's own decoder, on the engine's own content (ADR-0018).
        var image = try asset.png.decode(gpa, sprite_sheet_png, .{});
        defer image.deinit(gpa);
        const sheet = try renderer.atlasAdd(atlas, image);

        var glyphs = try asset.png.decode(gpa, font_png, .{});
        defer glyphs.deinit(gpa);
        const font: render2d.BitmapFont = .{
            .glyphs = try renderer.atlasAdd(atlas, glyphs),
            .cell = .{ .width = 8, .height = 8 },
            .columns = 16,
            .first_codepoint = ' ',
            .glyph_count = 95,
        };

        // An image from memory, not from a file: `atlasAdd` takes an `asset.Image` and
        // does not care where it came from, which is what lets a game generate one.
        var white = try asset.Image.alloc(gpa, 8, 8);
        defer white.deinit(gpa);
        @memset(white.pixels, 0xFF);
        const patch = try renderer.atlasAdd(atlas, white);
        const blank = patch.sub(2, 2, 4, 4);

        log.info("atlas {d}x{d}: sheet {d}x{d}, font {d}x{d}, {d:.1}% full", .{
            atlas_size.width,                           atlas_size.height,
            image.width,                                image.height,
            glyphs.width,                               glyphs.height,
            (renderer.atlasFill(atlas) orelse 0) * 100,
        });

        const seeds = try gpa.alloc(Seed, count);
        errdefer gpa.free(seeds);

        // Explicit seed and stream, never the clock: the same build draws the same field
        // on every run, which is what makes a visual difference mean something.
        var rng: core.rng.Pcg32 = .init(0x5EED_5A11_D0_1234, 1);
        for (seeds) |*seed| {
            const cell = rng.below(16);
            seed.* = .{
                .home = .init(
                    (rng.float01() - 0.5) * 1400,
                    (rng.float01() - 0.5) * 900,
                ),
                .radius = 10 + rng.float01() * 90,
                .speed = 0.2 + rng.float01() * 1.1,
                .phase = rng.float01() * std.math.tau,
                .size = 14 + rng.float01() * 26,
                .spin = (rng.float01() - 0.5) * 2.0,
                .cell = @intCast(cell),
                .tint = .srgb8(255, 255, 255, 160 + @as(u8, @intCast(rng.below(96)))),
                // A tenth of them additive, so both pipelines are on screen and a
                // regression in either is visible rather than theoretical.
                .blend = if (rng.below(10) == 0) .additive else .alpha,
            };
        }

        return .{
            .gpa = gpa,
            .renderer = renderer,
            .atlas = atlas,
            .sheet = sheet,
            .blank = blank,
            .font = font,
            .seeds = seeds,
            .camera = .{ .viewport = .init(0, 0, 1280, 720) },
        };
    }

    fn deinit(self: *SpriteField) void {
        self.gpa.free(self.seeds);
        self.renderer.deinit();
    }

    /// What one sprite looks like right now.
    ///
    /// **One definition, used by both drawing and picking.** Two would agree until the
    /// day one of them changed, and the symptom would be clicks landing next to sprites
    /// rather than on them — which is exactly the sort of bug that gets blamed on the
    /// maths instead of on the duplication.
    fn spriteAt(self: *const SpriteField, index: usize, seconds: f32) render2d.Sprite {
        const seed = self.seeds[index];
        const angle = seed.phase + seconds * seed.speed;

        // In the sheet's own pixels, not the atlas's. `Region.sub` is what makes that
        // possible, and it is why packing the sheet into an atlas changed this line from
        // dividing by four to dividing by four.
        const cell_w = self.sheet.size_px.width / grid;
        const cell_h = self.sheet.size_px.height / grid;
        const cell = self.sheet.sub(
            (seed.cell % grid) * cell_w,
            (seed.cell / grid) * cell_h,
            cell_w,
            cell_h,
        );

        return .{
            .texture = cell.texture,
            .position = .init(
                seed.home.x + @cos(angle) * seed.radius,
                seed.home.y + @sin(angle) * seed.radius,
            ),
            .size = .init(seed.size, seed.size),
            .uv = cell.uv,
            .rotation = angle * seed.spin,
            .tint = seed.tint,
            .blend = seed.blend,
            // Four layers, so the sort is doing real work rather than sorting a
            // constant. Additive sprites ride on top, where they belong.
            .layer = if (seed.blend == .additive) 3 else @intCast(index % 3),
        };
    }

    /// Camera control and picking — the sample's input policy, and the half of "a 2D
    /// camera with pan and zoom" that is not maths.
    ///
    /// Outside the fixed step, like resizing and for the same reason: where the camera
    /// is looking is presentation, not simulation. That is also why it may use
    /// `frameDelta` — a wall-clock number that simulation is forbidden to touch (I9).
    fn control(self: *SpriteField, engine: *app.Engine, seconds: f32) void {
        const info = engine.windowInfo();
        const width: f32 = if (info) |i| @floatFromInt(i.logical_size.width) else 1280;
        const height: f32 = if (info) |i| @floatFromInt(i.logical_size.height) else 720;

        // Refreshed every frame, not just on resize: a camera holding a stale viewport
        // puts `screenToWorld` out by half the difference, and picking then misses by a
        // margin that grows the more the window has changed.
        self.camera.viewport = .init(0, 0, width, height);

        const in = &engine.input;
        const dt = engine.frameDelta().toSecondsF32();

        if (in.wasPressed(.c)) {
            self.camera.center = .zero;
            self.camera.zoom = 1;
            self.selected = null;
            log.info("camera recentred", .{});
        }

        // Screen-space pan. `w` moves the view up, which is *negative* screen Y, because
        // screen space is Y-down and `panByScreen` speaks screen space.
        var direction: core.math.Vec2 = .zero;
        if (in.isHeld(.a) or in.isHeld(.left)) direction.x -= 1;
        if (in.isHeld(.d) or in.isHeld(.right)) direction.x += 1;
        if (in.isHeld(.w) or in.isHeld(.up)) direction.y -= 1;
        if (in.isHeld(.s) or in.isHeld(.down)) direction.y += 1;
        if (!direction.eql(.zero)) {
            const speed = if (in.modifiers.shift) fast_pan_speed else pan_speed;
            self.pan(direction.normalize().scale(speed * dt));
        }

        // Drag to pan. The negation is the difference between moving the camera and
        // moving the content: dragging right should bring what is on the left into view.
        if (in.mouse.isHeld(.right) or in.mouse.isHeld(.middle)) {
            self.pan(in.mouse.motion.neg());
        }

        if (in.mouse.wheel.y != 0) {
            // Multiplicative, so one notch feels the same at any zoom. Additive steps
            // are glacial when zoomed out and violent when zoomed in.
            const wanted = std.math.clamp(
                self.camera.zoom * @exp(in.mouse.wheel.y * 0.15),
                min_zoom,
                max_zoom,
            );
            self.camera.zoomAround(in.mouse.position, wanted) catch |err| {
                log.warn("zoom refused: {t}", .{err});
            };
        }

        // A left click, or the scripted stand-in for one. Same code path either way,
        // which is the point: a check that exercises a *different* path proves nothing
        // about the one a person uses.
        const clicked_at: ?core.math.Vec2 = if (in.mouse.wasPressed(.left))
            in.mouse.position
        else if (self.pick_every) |every|
            if (engine.frame_index > 0 and engine.frame_index % every == 0)
                core.math.Vec2.init(width / 2, height / 2)
            else
                null
        else
            null;

        if (clicked_at) |at| {
            const world = self.camera.screenToWorld(at);
            self.selected = self.pick(world, seconds);
            if (self.selected) |index| {
                log.info("picked sprite {d} of {d} at world ({d:.1}, {d:.1}), zoom {d:.2}", .{
                    index, self.seeds.len, world.x, world.y, self.camera.zoom,
                });
            } else {
                log.info("nothing at world ({d:.1}, {d:.1})", .{ world.x, world.y });
            }
        }
    }

    /// A pan that reports rather than asserts. Only unusable numbers can be refused, and
    /// those arrive from devices and config files, so this is the "invalid input" case
    /// rather than the "programmer error" one (`CLAUDE.md` §7).
    fn pan(self: *SpriteField, delta: core.math.Vec2) void {
        self.camera.panByScreen(delta) catch |err| log.warn("pan refused: {t}", .{err});
    }

    /// Which sprite is under a world point, or none.
    ///
    /// A linear scan, deliberately. The renderer keeps no sprite list to search — a
    /// sprite becomes vertices the moment it is drawn — so picking is the game's loop
    /// over the game's own objects. A spatial index belongs with the thing that owns
    /// positions, which is M4's world, not M2's renderer.
    fn pick(self: *const SpriteField, world: core.math.Vec2, seconds: f32) ?usize {
        var best: ?usize = null;
        var best_layer: i16 = 0;
        for (0..self.seeds.len) |index| {
            const sprite = self.spriteAt(index, seconds);
            // World space, so `.up` — the sample's picking is of world sprites.
            if (!render2d.containsPoint(sprite, world, .up)) continue;
            // Later in the draw order wins, and the draw order is `(layer, submission
            // index)` — the batcher's own sort key. So "topmost" means the same thing to
            // the pick as it does to the GPU, rather than being a second guess at it.
            if (best == null or sprite.layer >= best_layer) {
                best = index;
                best_layer = sprite.layer;
            }
        }
        return best;
    }

    /// Builds this frame's draw list. This is the game's half of rendering, and it never
    /// sees a command buffer or a render pass: `app.Engine.renderFrame` owns those.
    fn submit(self: *SpriteField, engine: *app.Engine, seconds: f32) !void {
        const scale: f32 = if (engine.windowInfo()) |i| i.scale else 1;

        try self.renderer.begin(.{ .camera = self.camera, .pixel_scale = scale });

        for (0..self.seeds.len) |index| {
            try self.renderer.drawSprite(self.spriteAt(index, seconds));
        }

        if (self.selected) |index| {
            const sprite = self.spriteAt(index, seconds);
            try self.outline(sprite);
            try self.label(index, sprite);
        }

        try self.banner();
        try self.hud(engine);
    }

    /// The statistics readout, in **screen space**, which is what views are for.
    ///
    /// `setView` once and then draw: the panel and every glyph after it are in screen
    /// points, the same units the mouse is reported in, and none of it moves when the
    /// camera does. Nothing here converts a coordinate, which is the whole gain — before
    /// views, a HUD meant running every position through `screenToWorld` and dividing
    /// every size by the zoom, and it was still wrong under camera rotation.
    ///
    /// The numbers are **last frame's**, because this frame's are not known until the
    /// batcher has planned — which happens after the game has finished submitting. One
    /// frame of lag in a diagnostic is not worth a second pass to remove.
    fn hud(self: *SpriteField, engine: *app.Engine) !void {
        const stats = self.renderer.frameStats();
        const info = engine.windowInfo();
        const width: f32 = if (info) |i| @floatFromInt(i.logical_size.width) else 1280;

        var buffer: [512]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            "{d:.1}ms  {d} sprites  {d} glyphs\n" ++
                "{d} batches  {d} draw calls  {d} views\n" ++
                "{d} KiB vertices  {d} buffers  zoom {d:.2}",
            .{
                engine.frameDelta().toSecondsF32() * 1000,
                stats.sprites,
                stats.glyphs,
                stats.batches,
                stats.draw_calls,
                stats.views,
                stats.vertex_bytes / 1024,
                stats.buffers_used,
                self.camera.zoom,
            },
            // A statistics line that cannot be formatted is not worth failing a frame for.
        ) catch return;

        try self.renderer.setView(.screen);
        defer self.renderer.setView(.world) catch {};

        const options: render2d.TextOptions = .{
            .position = .init(hud_margin + hud_padding, hud_margin + hud_padding),
            .scale = 2,
            .line_spacing = 4,
            .tint = .srgb8(190, 235, 255, 255),
        };
        const size = render2d.measureText(self.font, text, options);

        // A panel behind it, so the readout is legible over whatever it lands on. Drawn
        // from the same atlas as the glyphs, so it costs no draw call of its own.
        try self.renderer.drawSprite(.{
            .texture = self.blank.texture,
            .uv = self.blank.uv,
            .position = .init(hud_margin, hud_margin),
            .size = .init(size.x + hud_padding * 2, size.y + hud_padding * 2),
            .origin = .init(0, 0),
            .tint = .srgb8(0, 0, 0, 150),
            .layer = 0,
        });
        try self.renderer.drawText(self.font, text, .{
            .position = options.position,
            .scale = options.scale,
            .line_spacing = options.line_spacing,
            .tint = options.tint,
            .layer = 1,
        });

        // Right-aligned, to show that `measureText` is usable for layout and not only for
        // centring — and that screen space has a right-hand edge, which world space does
        // not.
        const help = "wasd pan  wheel zoom  click picks  c recentres";
        const help_options: render2d.TextOptions = .{ .position = .zero, .scale = 1.5 };
        const help_size = render2d.measureText(self.font, help, help_options);
        const help_at: core.math.Vec2 = .init(
            width - help_size.x - hud_margin - hud_padding,
            hud_margin + hud_padding,
        );
        try self.renderer.drawSprite(.{
            .texture = self.blank.texture,
            .uv = self.blank.uv,
            .position = .init(help_at.x - hud_padding, hud_margin),
            .size = .init(help_size.x + hud_padding * 2, help_size.y + hud_padding * 2),
            .origin = .init(0, 0),
            .tint = .srgb8(0, 0, 0, 150),
            .layer = 0,
        });
        try self.renderer.drawText(self.font, help, .{
            .position = help_at,
            .scale = help_options.scale,
            .tint = .srgb8(180, 180, 200, 230),
            .layer = 1,
        });
    }

    /// Text at the world origin, in **world** units.
    ///
    /// It scrolls and scales with the camera, because that is what world-space text is
    /// for: a sign on a wall, a name over a character. Contrast `label`, which is
    /// deliberately the other kind. On-screen statistics are a third kind again — they
    /// belong in a screen-space pass, which M2's last step is about.
    fn banner(self: *SpriteField) !void {
        try self.renderer.drawText(self.font, "foundry sandbox\nworld origin", .{
            .position = .init(-56, 120),
            .scale = 2,
            .line_spacing = 4,
            .tint = .srgb8(120, 200, 255, 220),
            .layer = 4,
        });
    }

    /// The selected sprite's index, drawn above it at a **constant size on screen**.
    ///
    /// Dividing the scale by the zoom is the same trick the outline uses for its
    /// thickness, and for the same reason: a label that shrank to nothing when zoomed out
    /// would stop being a label. `measureText` centres it, and it runs the layout the
    /// drawing runs, so the two cannot disagree about how wide the number is.
    fn label(self: *SpriteField, index: usize, sprite: render2d.Sprite) !void {
        var buffer: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "#{d}", .{index}) catch return;

        const options: render2d.TextOptions = .{
            .position = .zero,
            .scale = 1.5 / self.camera.zoom,
            .tint = .srgb8(255, 236, 120, 255),
            .layer = std.math.maxInt(i16),
        };
        const size = render2d.measureText(self.font, text, options);

        try self.renderer.drawText(self.font, text, .{
            .position = .init(
                sprite.position.x - size.x / 2,
                sprite.position.y + sprite.size.y / 2 + size.y + 4 / self.camera.zoom,
            ),
            .scale = options.scale,
            .tint = options.tint,
            .layer = options.layer,
        });
    }

    /// Four thin quads around a sprite, so that picking is visibly working rather than
    /// only logged.
    fn outline(self: *SpriteField, sprite: render2d.Sprite) !void {
        // Two points wide on screen whatever the zoom: a fixed world thickness is
        // invisible when zoomed out and a slab when zoomed in.
        const thickness = 2 / self.camera.zoom;
        const half_w = sprite.size.x / 2;
        const half_h = sprite.size.y / 2;
        const c = @cos(sprite.rotation);
        const s = @sin(sprite.rotation);

        const edges = [4]struct { offset: core.math.Vec2, size: core.math.Vec2 }{
            .{ .offset = .init(0, half_h), .size = .init(sprite.size.x + thickness, thickness) },
            .{ .offset = .init(0, -half_h), .size = .init(sprite.size.x + thickness, thickness) },
            .{ .offset = .init(-half_w, 0), .size = .init(thickness, sprite.size.y + thickness) },
            .{ .offset = .init(half_w, 0), .size = .init(thickness, sprite.size.y + thickness) },
        };

        for (edges) |edge| {
            try self.renderer.drawSprite(.{
                .texture = self.blank.texture,
                .uv = self.blank.uv,
                // The offset turns with the sprite, so the box stays around it rather
                // than beside it.
                .position = .init(
                    sprite.position.x + (edge.offset.x * c - edge.offset.y * s),
                    sprite.position.y + (edge.offset.x * s + edge.offset.y * c),
                ),
                .size = edge.size,
                .rotation = sprite.rotation,
                .tint = .srgb8(255, 236, 120, 255),
                // Above everything, including the additive layer.
                .layer = std.math.maxInt(i16),
            });
        }
    }
};

/// The background, which drifts slowly so that a frozen frame is obvious at a glance.
///
/// Linear values, because the surface is an `_srgb` format and the GPU encodes on write.
/// A clear colour written in sRGB numbers is the same mistake as a tint written in them.
fn clearColor(engine: *app.Engine) [4]f32 {
    const seconds = @as(f32, @floatFromInt(engine.elapsed().toMillis())) / 1000.0;
    const t = 0.5 + 0.5 * @sin(seconds * 0.25);
    return .{ 0.012 + 0.010 * t, 0.016 + 0.012 * t, 0.030 + 0.018 * t, 1.0 };
}

/// How many sprites to draw. Overridable, because "thousands at a stable frame rate" is
/// M2's exit criterion and a number you cannot change is a number you cannot test.
fn spriteCount(engine: *app.Engine) u32 {
    const text = engine.os.envVar("FOUNDRY_SANDBOX_SPRITES") orelse return 4000;
    return std.fmt.parseInt(u32, text, 10) catch |err| {
        log.warn("FOUNDRY_SANDBOX_SPRITES='{s}' is not a count ({t}); using 4000", .{ text, err });
        return 4000;
    };
}

const size_cycle = [_]platform.Size{
    .{ .width = 1280, .height = 720 },
    .{ .width = 900, .height = 900 },
    .{ .width = 1400, .height = 500 },
    .{ .width = 640, .height = 480 },
};

/// Asks for a new window size, and carries on if the answer is no.
///
/// A window manager may decline — a tiling compositor will — and a size read from a config
/// file may be nonsense. Neither is a programmer error, so both are reported at `warn` and
/// the frame continues (`CLAUDE.md` §7).
fn requestResize(engine: *app.Engine, size: platform.Size) void {
    engine.setWindowSize(size) catch |err| {
        log.warn("resize to {d}x{d} refused: {t}", .{ size.width, size.height, err });
        return;
    };
    log.info("requested {d}x{d}; watch for the resized event", .{ size.width, size.height });
}

/// A "do this every N frames" knob, or null when it is unset or zero.
///
/// Same rationale as `FOUNDRY_SANDBOX_FRAMES`, and read the same way: a windowed run that
/// cannot be scripted can only be checked by a person remembering to check it, and the
/// resize path is precisely the one that went unverified for two sessions because of that.
/// `FOUNDRY_SANDBOX_RESIZE_EVERY` drives the resize cycle; `FOUNDRY_SANDBOX_PICK_EVERY`
/// picks at the window centre, taking exactly the path a click takes.
fn everyFrames(engine: *app.Engine, name: []const u8) ?u64 {
    const raw = engine.os.envVar(name) orelse return null;
    const n = std.fmt.parseInt(u64, std.mem.trim(u8, raw, " "), 10) catch {
        log.warn("{s}='{s}' is not a number; ignoring", .{ name, raw });
        return null;
    };
    return if (n == 0) null else n;
}

/// What surface the renderer will eventually want here.
///
/// Compile-time, because it is a property of the target rather than of the machine. Only
/// Metal exists so far (ADR-0003); the others arrive with their backends.
const wanted_surface: platform.SurfaceKind = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .visionos => .metal_layer,
    else => .none,
};

/// How many frames to run before stopping, or null to run until asked to quit.
///
/// Reads `FOUNDRY_SANDBOX_FRAMES` through the engine's own environment plumbing rather
/// than from the air — which is both the rule (I9) and a demonstration of it.
fn frameLimit(engine: *app.Engine, headless: bool) ?u64 {
    if (engine.os.envVar("FOUNDRY_SANDBOX_FRAMES")) |raw| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, raw, " "), 10)) |n| {
            return n;
        } else |_| {
            // Bad external input: reported and ignored, never asserted on.
            log.warn("FOUNDRY_SANDBOX_FRAMES='{s}' is not a number; ignoring", .{raw});
        }
    }
    return if (headless) default_headless_frames else null;
}

/// Logs what happened, which is the whole of M0's "responds to input".
fn report(ev: platform.Event) void {
    switch (ev) {
        .quit_requested => log.info("quit requested", .{}),
        .window_closed => log.info("window closed", .{}),
        .window_resized => |e| log.info("resized: {d}x{d} points, {d}x{d} pixels, scale {d:.2}", .{
            e.logical_size.width, e.logical_size.height,
            e.pixel_size.width,   e.pixel_size.height,
            e.scale,
        }),
        .window_focus_gained => log.debug("focus gained", .{}),
        .window_focus_lost => log.debug("focus lost", .{}),

        // Keys are physical positions: `.q` is the top-left letter key whatever the
        // layout prints on it. Characters come from `text_input` instead.
        .key_down => |e| if (!e.repeat) log.info("key down: {s}{s}", .{ e.key.name(), modifierSuffix(e.modifiers) }),
        .key_up => |e| log.debug("key up: {s}", .{e.key.name()}),
        .text_input => |e| log.info("text: '{s}'", .{e.text()}),

        .mouse_button_down => |e| log.info("mouse down: {s} at ({d:.0}, {d:.0})", .{
            e.button.name(), e.position.x, e.position.y,
        }),
        .mouse_button_up => |e| log.debug("mouse up: {s}", .{e.button.name()}),
        .mouse_wheel => |e| log.info("wheel: ({d:.2}, {d:.2})", .{ e.delta.x, e.delta.y }),
        // Every frame it moves, so it stays at trace.
        .mouse_moved => |e| log.trace("mouse at ({d:.0}, {d:.0})", .{ e.position.x, e.position.y }),
    }
}

fn modifierSuffix(mods: platform.Modifiers) []const u8 {
    if (mods.eql(.none)) return "";
    if (mods.super) return " +super";
    if (mods.ctrl) return " +ctrl";
    if (mods.alt) return " +alt";
    if (mods.shift) return " +shift";
    return "";
}
