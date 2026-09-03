//! `samples/sandbox` — the smallest thing that exercises the engine.
//!
//! It opens a window, logs input, runs the fixed-timestep loop, clears the screen and
//! exits cleanly.
//!
//! The clear is deliberately run on **both** backends rather than only where it is visible.
//! Under `-Drhi=null` the same command stream goes through the validation backend, so the
//! headless run is a continuous check that what Metal accepts also satisfies the ten rules
//! of `docs/design/rhi.md` §11 — which is exactly the cross-check M1 exists to establish.
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
const platform = @import("platform");
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
        log.info("escape or the window's close button quits", .{});
    }

    var reported_tick: u64 = 0;

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

        // Rendering. Interpolation by `engine.alpha()` arrives with something that moves;
        // a clear has nothing to interpolate.
        renderFrame(engine) catch |err| switch (err) {
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

/// One frame of rendering: a single pass that clears the surface and ends.
///
/// Short, and every line of it is contract. The attachment declares the state the surface
/// arrives in and the state it leaves in (`rhi.md` §6) — `undefined` in, because nothing in
/// last frame's image is worth preserving, and `present` out, because the display takes it
/// next. Metal discards both declarations and the validation backend checks them, which is
/// the arrangement that keeps the interface honest while Metal is the only real backend.
fn renderFrame(engine: *app.Engine) !void {
    const frame = try engine.gpu.beginFrame();

    var cmd = try engine.gpu.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .label = "clear",
        .color = &.{.{
            .texture = frame.surface_texture,
            .load = .{ .clear = .{ .color = clearColor(engine) } },
            .store = .store,
            .initial_state = .undefined,
            .final_state = .present,
        }},
    });
    pass.end();
    try cmd.submit();

    try engine.gpu.endFrame();
}

/// A colour that moves, so that a stalled loop looks stalled rather than merely dark.
///
/// Driven by **simulated** time rather than the wall clock, so the same run produces the
/// same colours every time (I9). Reading the clock here instead would be exactly the hidden
/// input the determinism rule exists to forbid.
fn clearColor(engine: *app.Engine) [4]f32 {
    const seconds = @as(f32, @floatFromInt(engine.elapsed().toMillis())) / 1000.0;
    const t = 0.5 + 0.5 * @sin(seconds * 0.8);
    return .{ 0.05 + 0.10 * t, 0.08 + 0.13 * t, 0.15 + 0.20 * t, 1.0 };
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
