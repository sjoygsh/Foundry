//! `samples/sandbox` — the smallest thing that exercises the engine.
//!
//! It opens a window, logs input, runs the fixed-timestep loop, draws a textured quad that
//! survives being resized, and exits cleanly.
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
        log.info("R resizes the window; escape or the close button quits", .{});
    }

    var reported_tick: u64 = 0;
    var size_index: usize = 0;
    const auto_resize_every = autoResizeEvery(engine);

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
            log.debug("frame {d}: {d} sprites, {d} batches, {d} draw calls, {d} KiB of vertices", .{
                engine.frame_index,
                stats.sprites,
                stats.batches,
                stats.draw_calls,
                stats.vertex_bytes / 1024,
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

/// A field of sprites, which is the thing M2 exists to make possible.
///
/// Every sprite's parameters come from one seeded generator run once at startup, so the
/// same build draws the same field every time (I9). The animation is a pure function of
/// simulated time, so it is reproducible too.
const SpriteField = struct {
    gpa: std.mem.Allocator,
    renderer: render2d.Renderer,
    sheet: render2d.TextureHandle,
    seeds: []Seed,

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

    /// The sheet is a 4x4 grid, so a cell is a quarter of the texture in each axis.
    const grid: f32 = 4;

    fn init(gpa: std.mem.Allocator, device: *rhi.Device, count: u32) !SpriteField {
        var renderer = try render2d.Renderer.init(gpa, device, .{
            .frames_in_flight = 2,
        });
        errdefer renderer.deinit();

        // The engine's own decoder, on the engine's own content (ADR-0018).
        var image = try asset.png.decode(gpa, sprite_sheet_png, .{});
        defer image.deinit(gpa);
        log.info("sprite sheet: {d}x{d}, {d} bytes decoded", .{
            image.width, image.height, image.byteSize(),
        });

        const sheet = try renderer.createTexture(image, .{
            .label = "sandbox sprites",
            // Nearest, so scaling up shows the sheet's pixels rather than a blur. The
            // default, spelled out because it is the interesting choice.
            .filter = .nearest,
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

        return .{ .gpa = gpa, .renderer = renderer, .sheet = sheet, .seeds = seeds };
    }

    fn deinit(self: *SpriteField) void {
        self.gpa.free(self.seeds);
        self.renderer.deinit();
    }

    /// Builds this frame's draw list. This is the game's half of rendering, and it never
    /// sees a command buffer or a render pass: `app.Engine.renderFrame` owns those.
    fn submit(self: *SpriteField, engine: *app.Engine, seconds: f32) !void {
        const info = engine.windowInfo();
        const width: f32 = if (info) |i| @floatFromInt(i.logical_size.width) else 1280;
        const height: f32 = if (info) |i| @floatFromInt(i.logical_size.height) else 720;
        const scale: f32 = if (info) |i| i.scale else 1;

        try self.renderer.begin(.{
            .camera = .{
                .viewport = .init(0, 0, width, height),
                // Slow drift and a gentle breathing zoom, so a resize is obviously
                // handled rather than obviously frozen.
                .center = .init(@sin(seconds * 0.11) * 120, @cos(seconds * 0.09) * 80),
                .zoom = 0.85 + 0.15 * @sin(seconds * 0.3),
            },
            .pixel_scale = scale,
        });

        const cell_uv = 1.0 / grid;
        for (self.seeds, 0..) |seed, i| {
            const angle = seed.phase + seconds * seed.speed;
            const column: f32 = @floatFromInt(seed.cell % 4);
            const row: f32 = @floatFromInt(seed.cell / 4);

            try self.renderer.drawSprite(.{
                .texture = self.sheet,
                .position = .init(
                    seed.home.x + @cos(angle) * seed.radius,
                    seed.home.y + @sin(angle) * seed.radius,
                ),
                .size = .init(seed.size, seed.size),
                .uv = .init(column * cell_uv, row * cell_uv, cell_uv, cell_uv),
                .rotation = angle * seed.spin,
                .tint = seed.tint,
                .blend = seed.blend,
                // Four layers, so the sort is doing real work rather than sorting a
                // constant. Additive sprites ride on top, where they belong.
                .layer = if (seed.blend == .additive) 3 else @intCast(i % 3),
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

/// How often to advance `size_cycle` on its own, or null to only do it on `R`.
///
/// Same rationale as `FOUNDRY_SANDBOX_FRAMES`, and read the same way: a windowed run that
/// cannot be scripted can only be checked by a person remembering to check it, and the
/// resize path is precisely the one that went unverified for two sessions because of that.
fn autoResizeEvery(engine: *app.Engine) ?u64 {
    const raw = engine.os.envVar("FOUNDRY_SANDBOX_RESIZE_EVERY") orelse return null;
    const n = std.fmt.parseInt(u64, std.mem.trim(u8, raw, " "), 10) catch {
        log.warn("FOUNDRY_SANDBOX_RESIZE_EVERY='{s}' is not a number; ignoring", .{raw});
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
