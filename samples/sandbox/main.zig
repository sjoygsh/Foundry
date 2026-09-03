//! `samples/sandbox` — the smallest thing that exercises the engine.
//!
//! It opens a window, logs input, runs the fixed-timestep loop, draws a textured quad and
//! exits cleanly.
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

    // Everything the quad needs, created once and held for the run. There is deliberately
    // no explicit teardown: `Device.deinit` reclaims what is still alive, and the Metal
    // backend waits on every in-flight frame before it does (see `Quad` below on why a
    // sample should not be hand-rolling destruction order yet).
    const quad = try Quad.init(engine.gpu);

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

        // Rendering. The quad's motion is driven by simulated time rather than
        // interpolated by `engine.alpha()`; interpolation arrives with M4's entities, which
        // is the first thing that has a previous and a current state to interpolate between.
        renderFrame(engine, &quad) catch |err| switch (err) {
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

/// One frame of rendering: a single pass that clears the surface and draws the quad.
///
/// Short, and every line of it is contract. The attachment declares the state the surface
/// arrives in and the state it leaves in (`rhi.md` §6) — `undefined` in, because nothing in
/// last frame's image is worth preserving, and `present` out, because the display takes it
/// next. Metal discards both declarations and the validation backend checks them, which is
/// the arrangement that keeps the interface honest while Metal is the only real backend.
fn renderFrame(engine: *app.Engine, quad: *const Quad) !void {
    const frame = try engine.gpu.beginFrame();

    var cmd = try engine.gpu.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .label = "quad",
        .color = &.{.{
            .texture = frame.surface_texture,
            .load = .{ .clear = .{ .color = clearColor(engine) } },
            .store = .store,
            .initial_state = .undefined,
            .final_state = .present,
        }},
    });

    pass.setPipeline(quad.pipeline);
    // Group 0 is the quad's material: its texture, its sampler and its one uniform buffer.
    // Which Metal argument-table index each of those lands on is decided by `rhi.md` §9 and
    // spelled out in `shaders/quad.metal` beside the shader that reads them.
    pass.setBindGroup(0, quad.group);
    pass.setVertexBuffer(0, quad.vertices, 0);
    pass.setIndexBuffer(quad.indices, .uint16, 0);
    // Inline constants are command stream data, not a resource, so they can change every
    // frame without any of the ring buffering `quad.uniform` would need (§9).
    const constants = quadConstants(engine);
    pass.setInlineConstants(std.mem.asBytes(&constants));
    pass.drawIndexed(.{ .index_count = Quad.index_count });

    pass.end();
    try cmd.submit();

    try engine.gpu.endFrame();
}

/// The per-frame inline constants: where the quad is, and what colour it is tinted.
///
/// Driven by **simulated** time, like `clearColor`, so the same run produces the same frames
/// every time (I9). The aspect correction is the interesting part: it is what makes a
/// window resize visible as *correct* rather than merely non-fatal, because a quad that is
/// still square after the window changes shape proves the swapchain and the surface size
/// both followed.
fn quadConstants(engine: *app.Engine) Constants {
    const seconds = @as(f32, @floatFromInt(engine.elapsed().toMillis())) / 1000.0;
    const t = 0.5 + 0.5 * @sin(seconds * 1.3);
    return .{
        // `mul(a, b)` applies `b` first: spin the quad in square space, then map that space
        // to the screen. The other order would shear it as it turned.
        .transform = aspectCorrection(engine).mul(core.math.Mat4.rotationZ(seconds * 0.35)),
        .tint = .{ 1.0, 0.85 + 0.15 * t, 0.72 + 0.28 * t, 1.0 },
    };
}

/// Squashes clip space so that a square stays square whatever shape the window is.
///
/// A real 2D camera with world and screen coordinate spaces is M2. This is the three lines
/// of it M1 actually needs, and writing more would be inventing the camera's design here
/// rather than where it belongs.
fn aspectCorrection(engine: *app.Engine) core.math.Mat4 {
    const info = engine.windowInfo() orelse return .identity;
    const w: f32 = @floatFromInt(info.pixel_size.width);
    const h: f32 = @floatFromInt(info.pixel_size.height);
    if (w <= 0 or h <= 0) return .identity;
    return if (w >= h)
        core.math.Mat4.scaling(core.math.Vec3.init(h / w, 1, 1))
    else
        core.math.Mat4.scaling(core.math.Vec3.init(1, w / h, 1));
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

// -- the textured quad -------------------------------------------------------------------

/// One vertex. `extern` because the GPU reads it, so the field order and padding are part
/// of the contract with `shaders/quad.metal` rather than Zig's business.
const Vertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
};

/// The inline constants — `rhi.md` §9's push-constant-style block, at Metal buffer 8.
///
/// Deliberately what *changes every frame*. Anything constant would be wasting command
/// stream bandwidth every draw, and anything much larger wanted a uniform buffer.
const Constants = extern struct {
    transform: core.math.Mat4,
    tint: [4]f32,
};

/// The one uniform buffer: group 0, binding 2, which §9's walk puts at Metal buffer 9.
///
/// Written once at startup and never again, deliberately. Rewriting a uniform buffer a
/// frame in flight may still be reading is exactly what rule 3 forbids, and the per-frame
/// ring that makes it safe is the renderer's job (M2), not a sample's. Keeping the two
/// kinds of per-draw data visibly separate here is the point.
const Frame = extern struct {
    modulate: [4]f32,
};

comptime {
    // `shaders/quad.metal` declares these same three structs in MSL. Nothing checks the two
    // against each other, so every size and offset that must agree is asserted here — the
    // same discipline as the shim's `_Static_assert`s, for the same reason: a silent
    // mismatch renders something subtly wrong with no error anywhere.
    std.debug.assert(@sizeOf(Vertex) == 16);
    std.debug.assert(@offsetOf(Vertex, "uv") == 8);
    // MSL's `float4x4` is column-major and `core.math.Mat4` stores columns, so the two agree
    // byte for byte and no transpose is needed on the way to the GPU.
    std.debug.assert(@sizeOf(Constants) == 80);
    std.debug.assert(@offsetOf(Constants, "tint") == 64);
    std.debug.assert(@sizeOf(Constants) <= rhi.max_inline_constant_bytes);
    std.debug.assert(@sizeOf(Frame) == 16);
}

/// The compiled shader.
///
/// Written as a `switch` on a comptime value so that a null build never analyses the Metal
/// branch: the `quad_metallib` module only exists when the build graph selected Metal.
/// `rhi/root.zig` uses the same shape to keep the Metal backend out of a null build.
const quad_shader: []const u8 = switch (rhi.backend) {
    // Produced by `metalLibrary` in `build.zig` (ADR-0015) and embedded. Loading it by
    // content ID instead needs the asset system, which is M3.
    .metal => @embedFile("quad_metallib"),
    // The validation backend compiles nothing and rejects only an empty descriptor, which
    // is what lets the identical command stream be checked headlessly.
    .null => "null-backend-shader",
};

/// Every GPU object the quad needs, created once.
///
/// **There is no `deinit`.** Not an oversight: the RHI's interface says a destroy is
/// deferred until no in-flight frame can reference the resource, and no backend implements
/// that yet (recorded in `PROJECT_STATE.md`). `Device.deinit` does the right thing — the
/// Metal backend waits on every in-flight command buffer before releasing anything — so a
/// sample holding its resources for the process lifetime is both correct today and honest
/// about what is not guaranteed. Resource lifetime through a frame ring is the renderer's
/// problem, and it arrives with the renderer.
const Quad = struct {
    shader: rhi.ShaderModuleHandle,
    vertices: rhi.BufferHandle,
    indices: rhi.BufferHandle,
    uniform: rhi.BufferHandle,
    texture: rhi.TextureHandle,
    sampler: rhi.SamplerHandle,
    group_layout: rhi.BindGroupLayoutHandle,
    group: rhi.BindGroupHandle,
    layout: rhi.PipelineLayoutHandle,
    pipeline: rhi.RenderPipelineHandle,

    const index_count: u32 = 6;

    /// A checkerboard is 8x8 because that is enough to make a wrong UV or a wrong sampler
    /// obvious and small enough to write by hand. Loading a real image is M2 (PNG decode);
    /// the upload path does not care which bytes it carries.
    const texture_extent: u32 = 8;

    /// Clip-space half-extent. The quad sits inside the window with a visible margin, so a
    /// resize that went wrong shows as clipping rather than as nothing at all.
    const half: f32 = 0.6;

    fn init(dev: *rhi.Device) !Quad {
        const shader = try dev.createShaderModule(.{ .label = "quad", .bytes = quad_shader });

        const vertices = [_]Vertex{
            // UV `v` is flipped against clip-space `y`: texture space runs downward and
            // clip space runs upward, in Metal as in Vulkan and D3D12.
            .{ .position = .{ -half, -half }, .uv = .{ 0, 1 } },
            .{ .position = .{ half, -half }, .uv = .{ 1, 1 } },
            .{ .position = .{ half, half }, .uv = .{ 1, 0 } },
            .{ .position = .{ -half, half }, .uv = .{ 0, 0 } },
        };
        const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };
        const uniform_value: Frame = .{ .modulate = .{ 1.0, 1.0, 1.0, 1.0 } };

        // One staging arena holding everything, copied out in one command buffer. This is
        // the shape a real uploader has, and it is why `MemoryIntent.upload` exists: the
        // destinations are all `device_local`, which §5 makes genuinely unmappable rather
        // than merely discouraged, so there is no shortcut available even on unified memory.
        const texel_bytes = texture_extent * texture_extent * 4;
        const vertex_at: u64 = 0;
        const index_at: u64 = align16(vertex_at + @sizeOf(@TypeOf(vertices)));
        const uniform_at: u64 = align16(index_at + @sizeOf(@TypeOf(indices)));
        const texel_at: u64 = align16(uniform_at + @sizeOf(Frame));
        const staging_size: u64 = texel_at + texel_bytes;

        const staging = try dev.createBuffer(.{
            .label = "quad staging",
            .size = staging_size,
            .usage = .{ .copy_src = true },
            .memory = .upload,
        });

        const vertex_buffer = try dev.createBuffer(.{
            .label = "quad vertices",
            .size = @sizeOf(@TypeOf(vertices)),
            .usage = .{ .vertex = true, .copy_dst = true },
        });
        const index_buffer = try dev.createBuffer(.{
            .label = "quad indices",
            .size = @sizeOf(@TypeOf(indices)),
            .usage = .{ .index = true, .copy_dst = true },
        });
        const uniform_buffer = try dev.createBuffer(.{
            .label = "quad uniform",
            .size = @sizeOf(Frame),
            .usage = .{ .uniform = true, .copy_dst = true },
        });

        const texture = try dev.createTexture(.{
            .label = "quad checkerboard",
            .size = .{ .width = texture_extent, .height = texture_extent },
            // sRGB, matching the surface, so the multiply in the fragment shader happens in
            // linear space and the write encodes back. Getting this wrong is invisible
            // until it is not.
            .format = .rgba8_unorm_srgb,
            .usage = .{ .sampled = true, .copy_dst = true },
        });

        const sampler = try dev.createSampler(.{
            .label = "quad sampler",
            // The defaults, spelled out because they are the interesting choice: `nearest`
            // is what a 2D engine wants, and a pixel-art texture filtered linearly is a bug
            // report (`resource.zig`).
            .min_filter = .nearest,
            .mag_filter = .nearest,
        });

        // -- fill the staging arena ------------------------------------------------------
        {
            const bytes = try dev.mapBuffer(staging);
            defer dev.unmapBuffer(staging);

            @memcpy(bytes[vertex_at..][0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
            @memcpy(bytes[index_at..][0..@sizeOf(@TypeOf(indices))], std.mem.asBytes(&indices));
            @memcpy(bytes[uniform_at..][0..@sizeOf(Frame)], std.mem.asBytes(&uniform_value));

            const texels = bytes[texel_at..][0..texel_bytes];
            for (0..texture_extent) |y| {
                for (0..texture_extent) |x| {
                    const light = ((x / 2) + (y / 2)) % 2 == 0;
                    const texel = texels[(y * texture_extent + x) * 4 ..][0..4];
                    texel.* = if (light)
                        .{ 236, 232, 220, 255 }
                    else
                        .{ 46, 58, 82, 255 };
                }
            }
        }

        // -- record the upload ------------------------------------------------------------
        //
        // Barriers are batched at the boundaries rather than issued per copy, which is the
        // shape §6 asks for: per-resource barriers between every command are what make
        // Vulkan slow, and every real renderer converges on batching them anyway.
        var cmd = try dev.beginCommandBuffer();

        try cmd.bufferBarrier(&.{
            .{ .buffer = vertex_buffer, .from = .undefined, .to = .copy_dst },
            .{ .buffer = index_buffer, .from = .undefined, .to = .copy_dst },
            .{ .buffer = uniform_buffer, .from = .undefined, .to = .copy_dst },
        });
        try cmd.copyBufferToBuffer(.{
            .src = staging,
            .src_offset = vertex_at,
            .dst = vertex_buffer,
            .size = @sizeOf(@TypeOf(vertices)),
        });
        try cmd.copyBufferToBuffer(.{
            .src = staging,
            .src_offset = index_at,
            .dst = index_buffer,
            .size = @sizeOf(@TypeOf(indices)),
        });
        try cmd.copyBufferToBuffer(.{
            .src = staging,
            .src_offset = uniform_at,
            .dst = uniform_buffer,
            .size = @sizeOf(Frame),
        });
        try cmd.bufferBarrier(&.{
            .{ .buffer = vertex_buffer, .from = .copy_dst, .to = .shader_read },
            .{ .buffer = index_buffer, .from = .copy_dst, .to = .shader_read },
            .{ .buffer = uniform_buffer, .from = .copy_dst, .to = .shader_read },
        });

        try cmd.textureBarrier(&.{.{ .texture = texture, .from = .undefined, .to = .copy_dst }});
        try cmd.copyBufferToTexture(.{
            .src = staging,
            .src_offset = texel_at,
            .dst = texture,
            .size = .{ .width = texture_extent, .height = texture_extent },
        });
        try cmd.textureBarrier(&.{.{ .texture = texture, .from = .copy_dst, .to = .shader_read }});

        try cmd.submit();

        // Safe here specifically because no frame has begun: nothing is in flight, so the
        // deferred-destroy guarantee the interface documents is not being leaned on.
        dev.destroyBuffer(staging);

        // -- binding ----------------------------------------------------------------------
        //
        // Ascending `binding` values are what §9's walk uses, not the order written here —
        // the backend sorts. Written in order anyway, because a reader should not have to
        // know that to predict the indices the shader declares.
        const group_layout = try dev.createBindGroupLayout(.{
            .label = "quad material",
            .entries = &.{
                .{ .binding = 0, .type = .sampled_texture, .visibility = .{ .fragment = true } },
                .{ .binding = 1, .type = .sampler, .visibility = .{ .fragment = true } },
                .{ .binding = 2, .type = .uniform_buffer, .visibility = .{ .fragment = true } },
            },
        });

        const group = try dev.createBindGroup(.{
            .label = "quad material",
            .layout = group_layout,
            .entries = &.{
                .{ .binding = 0, .resource = .{ .sampled_texture = texture } },
                .{ .binding = 1, .resource = .{ .sampler = sampler } },
                .{ .binding = 2, .resource = .{ .uniform_buffer = .{ .buffer = uniform_buffer } } },
            },
        });

        const layout = try dev.createPipelineLayout(.{
            .label = "quad",
            .bind_group_layouts = &.{group_layout},
            .inline_constant_bytes = @sizeOf(Constants),
        });

        const pipeline = try dev.createRenderPipeline(.{
            .label = "quad",
            .layout = layout,
            .vertex_shader = shader,
            .fragment_shader = shader,
            .vertex_buffers = &.{.{
                .stride = @sizeOf(Vertex),
                .attributes = &.{
                    .{ .location = 0, .offset = @offsetOf(Vertex, "position"), .format = .float32x2 },
                    .{ .location = 1, .offset = @offsetOf(Vertex, "uv"), .format = .float32x2 },
                },
            }},
            .color_targets = &.{.{
                // Rule 7: this must match the pass's attachment, so it is asked for rather
                // than assumed. The surface format is the device's to know, not the sample's.
                .format = dev.capabilities().surface_format,
                // Opaque here, but every sprite will want it, and it is the one part of the
                // pipeline descriptor nothing else exercises yet.
                .blend = .alpha_blend,
            }},
        });

        return .{
            .shader = shader,
            .vertices = vertex_buffer,
            .indices = index_buffer,
            .uniform = uniform_buffer,
            .texture = texture,
            .sampler = sampler,
            .group_layout = group_layout,
            .group = group,
            .layout = layout,
            .pipeline = pipeline,
        };
    }
};

/// Rounds up to 16, which is the alignment every one of these payloads is happy with and
/// the one Metal requires for a buffer bound to a `constant` address space argument.
fn align16(n: u64) u64 {
    return (n + 15) & ~@as(u64, 15);
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
