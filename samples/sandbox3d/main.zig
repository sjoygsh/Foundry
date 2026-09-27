//! `samples/sandbox3d` — the sample that gains each 3D capability from M19 to M25, as
//! `samples/sandbox` gained 2D's (`docs/design/render3d.md` §8).
//!
//! **M19's capability is depth.** Three meshes built here, never in the engine: a cube, a thin
//! slab that passes through it, and a tilted floor that cuts through both. The cube and the
//! slab turn about different axes, so where they intersect sweeps across their faces, which no
//! ordering of whole draws can fake: only the depth test can draw it. One line of `render2d`
//! text over the top is the first proof that 2D draws over a 3D frame.
//!
//! **This module is not given `rhi`** (`build.zig`), so reaching for a device, a pipeline or a
//! texture format here is a build error, not a review finding (CLAUDE.md §4.2). It reaches the
//! GPU only through `render3d`, `render2d` and `app.Engine.renderScene`.
//!
//! What it is told — window, clear colour, spin rates, font — is its package's
//! `sandbox3d:config` record, loaded through the path every package takes (I3). `--msaa=1|4`
//! is host bootstrap (ADR-0031), there so the same frame can be shown both ways.
//!
//! Environment, for scripted and evidence runs:
//! - `FOUNDRY_SANDBOX3D_FRAMES=n` stops after `n` frames;
//! - `FOUNDRY_SANDBOX3D_OVERLAY=0` draws no overlay pass, to measure what that pass costs;
//! - `FOUNDRY_SANDBOX3D_WORKERS=n` sets the engine's worker count.

const std = @import("std");

const app = @import("app");
const asset = @import("asset");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const render2d = @import("render2d");
const render3d = @import("render3d");

const Mat4 = core.math.Mat4;
const Quat = core.math.Quat;
const Vec3 = core.math.Vec3;

const log = core.log.scoped(.sandbox3d);

pub const std_options = app.std_options;

const app_name = "foundry-sandbox3d";
const config_id = "sandbox3d:config.main";
const default_headless_frames: u64 = 120;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var arguments = try init.minimal.args.iterateAllocator(gpa);
    defer arguments.deinit();
    _ = arguments.next(); // the program's own name
    var sample_count: u32 = 4;
    while (arguments.next()) |arg| {
        sample_count = parseMsaa(arg) orelse {
            var buffer: [256]u8 = undefined;
            var err = std.Io.File.stderr().writer(init.io, &buffer);
            err.interface.writeAll("usage: sandbox3d [--msaa=1|4]\n") catch {};
            err.interface.flush() catch {};
            // A mistyped command line is the operator's to fix, not a crash to trace.
            std.process.exit(2);
        };
    }

    const env = try app.environment(gpa, init);
    defer gpa.free(env);
    try run(gpa, env, sample_count);
}

fn parseMsaa(arg: []const u8) ?u32 {
    if (std.mem.eql(u8, arg, "--msaa=1")) return 1;
    if (std.mem.eql(u8, arg, "--msaa=4")) return 4;
    return null;
}

fn run(gpa: std.mem.Allocator, env: []const platform.os.EnvVar, sample_count: u32) !void {
    const headless = platform.backend == .null;

    // Discovery before the engine, as every host does it (`public-abi.md` §13): the
    // installation is the one root, and this package and the core one are required.
    var os = try platform.os.Os.init(gpa, .{ .env = env, .app_name = app_name });
    defer os.deinit();
    const content_dir = try app.contentDirOf(gpa, os, null);
    defer gpa.free(content_dir);

    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var mods = try app.ModSet.init(gpa, os, &.{.{ .dir = content_dir, .origin = .installed }}, .{
        .required = &.{ try data.contentId("foundry:core"), try data.contentId("sandbox3d:content") },
    }, &diags);
    defer mods.deinit();
    _ = mods.start(&.{}, &diags) catch |err| {
        for (diags.items.items) |d| log.err("content: {s}", .{d.message});
        return err;
    };
    for (diags.items.items) |d| log.warn("content: {s}", .{d.message});
    const packages = try mods.contentPackages(gpa);
    defer gpa.free(packages);

    var engine = try app.Engine.init(gpa, .{
        .env = env,
        .app_name = app_name,
        .log_level = .info,
        .headless = headless,
        .workers = workersFrom(env),
        .tick_rate_hz = 60,
        // On in every build: the frame pacing and the two passes' spans are what this
        // sample's evidence is made of (`render3d.md` §9).
        .profiler = true,
        .window = .{
            // Until the package says otherwise, a moment later.
            .title = "Foundry Sandbox 3D",
            .logical_width = 1280,
            .logical_height = 720,
            .surface = app.window_surface,
        },
        .content_dir = content_dir,
        .content = packages,
    });
    defer engine.deinit();

    var sample = try Sample.init(gpa, engine, sample_count);
    defer sample.deinit(engine);
    try sample.load(engine);

    const overlay_on = if (engine.os.envVar("FOUNDRY_SANDBOX3D_OVERLAY")) |v| !std.mem.eql(u8, v, "0") else true;
    const frame_limit = frameLimit(engine, headless);
    log.info("{s} backend, {d}x MSAA, overlay {s}{s}", .{
        app.graphics_backend,
        sample_count,
        if (overlay_on) "on" else "off",
        if (headless) ", headless" else "",
    });

    var skipped_frames: u64 = 0;
    while (!engine.shouldQuit()) {
        engine.beginFrame();
        if (sample.content_generation != engine.contentGeneration()) sample.refresh(engine);

        // Drained so the window keeps answering; the engine acts on a close itself.
        while (engine.nextEvent()) |_| {}
        if (engine.input.wasPressed(.escape)) engine.requestQuit();
        while (engine.nextStep()) |step| sample.step(step);

        var skipped = false;
        if (sample.draw(engine, overlay_on)) |drew| {
            skipped = !drew;
        } else |err| {
            // Only an image that is not there this frame — a minimised or occluded window —
            // is skipped. Anything else ends the run (ADR-0035).
            if (!app.Engine.frameSkippable(err)) {
                log.err("frame {d} failed: {t}", .{ engine.frame_index, err });
                return err;
            }
            skipped = true;
        }
        if (skipped) skipped_frames += 1;

        engine.endFrame();

        // A skipped frame presented nothing, and would otherwise spin a core. The null
        // backend has no swapchain to wait on either.
        if (skipped) engine.os.sleep(engine.step_delta);
        if (!headless and platform.backend == .null) engine.os.sleep(.fromMillis(2));

        if (frame_limit) |limit| {
            if (engine.frame_index >= limit) break;
        }
    }

    report(gpa, engine, &sample, skipped_frames);
}

/// What a run has to say for itself: how many frames, the pacing of the last ones and what
/// each stage of a frame cost.
fn report(gpa: std.mem.Allocator, engine: *app.Engine, sample: *const Sample, skipped_frames: u64) void {
    const stats = sample.world.frameStats();
    log.info("stopped after {d} frames ({d} skipped), {d} ticks; last frame {d} draws, {d} triangles", .{
        engine.frame_index, skipped_frames, engine.stepper.tick, stats.draws, stats.triangles,
    });

    const recorder = engine.profiler() orelse return;
    var totals: [240]i64 = undefined;
    var scratch: [240]i64 = undefined;
    var n: usize = 0;
    var it = recorder.frames();
    while (it.next()) |frame| {
        if (n == totals.len) {
            std.mem.copyForwards(i64, totals[0 .. totals.len - 1], totals[1..]);
            n -= 1;
        }
        totals[n] = frame.total_ns;
        n += 1;
    }
    const s = core.profile.summarise(totals[0..n], &scratch);
    log.info("pacing over the last {d} frames: min {d:.3}ms median {d:.3}ms p95 {d:.3}ms max {d:.3}ms", .{
        s.count, ms(s.min_ns), ms(s.median_ns), ms(s.p95_ns), ms(s.max_ns),
    });

    const medians = core.profile.spanMedians(recorder, gpa) catch return;
    defer gpa.free(medians);
    for (medians) |m| {
        log.info("span '{s}': median {d:.3}ms over {d} of {d} frames", .{
            recorder.nameOf(m.name), ms(m.median_ns), m.frames, recorder.frameCount(),
        });
    }
}

fn ms(ns: i64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(core.time.ns_per_ms));
}

fn frameLimit(engine: *app.Engine, headless: bool) ?u64 {
    if (engine.os.envVar("FOUNDRY_SANDBOX3D_FRAMES")) |text| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, text, " "), 10) catch null) |value| {
            if (value > 0) return value;
        }
        log.warn("FOUNDRY_SANDBOX3D_FRAMES is not a positive number; ignoring it", .{});
    }
    return if (headless) default_headless_frames else null;
}

fn workersFrom(env: []const platform.os.EnvVar) ?u16 {
    for (env) |v| {
        if (!std.mem.eql(u8, v.name, "FOUNDRY_SANDBOX3D_WORKERS")) continue;
        return std.fmt.parseInt(u16, v.value, 10) catch {
            log.warn("FOUNDRY_SANDBOX3D_WORKERS='{s}' is not a thread count; the engine chooses", .{v.value});
            return null;
        };
    }
    return null;
}

// ---------------------------------------------------------------------------------------
// What the package says.

const Settings = struct {
    title: []const u8,
    width: u32,
    height: u32,
    clear_linear: [4]f32,
    cube_radians_per_second: f32,
    slab_radians_per_second: f32,
    font: core.ContentId,

    const fallback: Settings = .{
        .title = "",
        .width = 1280,
        .height = 720,
        .clear_linear = .{ 0, 0, 0, 1 },
        .cube_radians_per_second = 0,
        .slab_radians_per_second = 0,
        .font = .none,
    };

    /// Content is untrusted, including this package's own: every field is checked here and
    /// falls back rather than reaching the renderer malformed (CLAUDE.md §7).
    fn read(engine: *app.Engine) Settings {
        const record = engine.store.lookup(core.ContentId.fromString(config_id)) orelse {
            log.err("'{s}' is not in any loaded package; using fallbacks", .{config_id});
            return fallback;
        };
        return .{
            .title = stringField(record, "title") orelse fallback.title,
            .width = sizeField(record, "width") orelse fallback.width,
            .height = sizeField(record, "height") orelse fallback.height,
            .clear_linear = colourField(record, "clear_linear") orelse fallback.clear_linear,
            .cube_radians_per_second = rateField(record, "cube_radians_per_second") orelse 0,
            .slab_radians_per_second = rateField(record, "slab_radians_per_second") orelse 0,
            .font = idField(record, "font") orelse .none,
        };
    }

    fn stringField(record: data.store.Record, name: []const u8) ?[]const u8 {
        const index = record.schema.fieldIndex(name) orelse return null;
        return (record.fields.stringAt(index) catch null) orelse null;
    }

    fn idField(record: data.store.Record, name: []const u8) ?core.ContentId {
        const index = record.schema.fieldIndex(name) orelse return null;
        return (record.fields.idAt(index) catch null) orelse null;
    }

    /// A window side: whole, positive and no larger than any display this runs on.
    fn sizeField(record: data.store.Record, name: []const u8) ?u32 {
        const index = record.schema.fieldIndex(name) orelse return null;
        const value = (record.fields.intAt(index) catch null) orelse return null;
        if (value < 64 or value > 16384) {
            log.warn("'{s}' = {d} is not a usable window side; using the fallback", .{ name, value });
            return null;
        }
        return @intCast(value);
    }

    /// Finite, and small enough that a turn is still visible as one.
    fn rateField(record: data.store.Record, name: []const u8) ?f32 {
        const index = record.schema.fieldIndex(name) orelse return null;
        const value = (record.fields.floatAt(index) catch null) orelse return null;
        if (!std.math.isFinite(value) or @abs(value) > 100) {
            log.warn("'{s}' is not a finite rate in radians per second; the mesh stays still", .{name});
            return null;
        }
        return @floatCast(value);
    }

    /// Four finite channels in [0, 1], linear RGBA.
    fn colourField(record: data.store.Record, name: []const u8) ?[4]f32 {
        const index = record.schema.fieldIndex(name) orelse return null;
        const list = (record.fields.listAt(index) catch null) orelse return null;
        var out: [4]f32 = undefined;
        if (list.len != out.len) return badColour(name);
        for (&out, 0..) |*channel, i| {
            const value = (list.floatAt(@intCast(i)) catch null) orelse return badColour(name);
            if (!std.math.isFinite(value) or value < 0 or value > 1) return badColour(name);
            channel.* = @floatCast(value);
        }
        return out;
    }

    fn badColour(name: []const u8) ?[4]f32 {
        log.warn("'{s}' is not four linear channels in [0, 1]; clearing to black", .{name});
        return null;
    }
};

// ---------------------------------------------------------------------------------------
// The sample.

const Sample = struct {
    gpa: std.mem.Allocator,
    sample_count: u32,
    world: render3d.Renderer,
    overlay: render2d.Renderer,

    cube: render3d.MeshHandle,
    slab: render3d.MeshHandle,
    floor: render3d.MeshHandle,

    settings: Settings = Settings.fallback,
    content_generation: u64 = 0,
    font_asset: asset.AssetHandle = .none,

    /// Each mesh's turn, advanced by whole simulation steps (I9).
    cube_angle: f32 = 0,
    slab_angle: f32 = 0,

    /// The camera does not move in M19. Placed as `Mat4.lookAt` places it: at `eye`, looking
    /// at the origin, with +Y as near up as it can be.
    const eye: Vec3 = .init(0, 2.3, 5.0);
    const cube_axis: Vec3 = .init(0.3, 1, 0.2);
    const slab_axis: Vec3 = .init(1, 0, 0.35);

    fn init(gpa: std.mem.Allocator, engine: *app.Engine, sample_count: u32) !Sample {
        var world = try render3d.Renderer.init(gpa, engine.gpu, .{ .sample_count = sample_count });
        errdefer world.deinit();
        var overlay = try render2d.Renderer.init(gpa, engine.gpu, .{ .jobs = engine.jobs() });
        errdefer overlay.deinit();

        const cube = try createBox(&world, .init(0.6, 0.6, 0.6), cube_faces, "sandbox3d cube");
        const slab = try createBox(&world, .init(1.3, 0.06, 0.9), slab_faces, "sandbox3d slab");
        const floor = try createFloor(&world);

        return .{
            .gpa = gpa,
            .sample_count = sample_count,
            .world = world,
            .overlay = overlay,
            .cube = cube,
            .slab = slab,
            .floor = floor,
        };
    }

    /// The texture loader borrows `&self.overlay`, so this waits until the sample has
    /// reached its final address.
    fn load(self: *Sample, engine: *app.Engine) !void {
        try engine.assets.registerLoader(self.gpa, render2d.textureLoader(&self.overlay));
        self.refresh(engine);
    }

    /// Everything derived from content, derived again whenever content changes.
    fn refresh(self: *Sample, engine: *app.Engine) void {
        const before = self.settings;
        self.settings = Settings.read(engine);
        self.content_generation = engine.contentGeneration();

        if (self.settings.title.len != 0) {
            engine.setWindowTitle(self.settings.title) catch |err|
                log.warn("the window title from '{s}' was refused ({t})", .{ config_id, err });
        }
        if (self.settings.width != before.width or self.settings.height != before.height) {
            engine.setWindowSize(.{ .width = self.settings.width, .height = self.settings.height }) catch |err|
                log.warn("the window size from '{s}' was refused ({t})", .{ config_id, err });
        }

        if (self.settings.font.eql(before.font) and !self.font_asset.isNone()) return;
        const fresh = if (self.settings.font.eql(.none))
            asset.AssetHandle.none
        else
            engine.assets.acquire(self.gpa, self.settings.font) catch |err| blk: {
                log.warn("the overlay font could not be loaded ({t}); no overlay text", .{err});
                break :blk asset.AssetHandle.none;
            };
        if (!self.font_asset.isNone()) engine.assets.release(self.font_asset);
        self.font_asset = fresh;
    }

    fn step(self: *Sample, s: app.Step) void {
        const dt = s.delta.toSecondsF32();
        self.cube_angle = wrap(self.cube_angle + self.settings.cube_radians_per_second * dt);
        self.slab_angle = wrap(self.slab_angle + self.settings.slab_radians_per_second * dt);
    }

    fn wrap(angle: f32) f32 {
        return @mod(angle, 2 * std.math.pi);
    }

    /// Records and submits one frame. False when there was nothing to draw into, which is
    /// what a minimised window's zero-sized surface gives.
    fn draw(self: *Sample, engine: *app.Engine, overlay_on: bool) !bool {
        const info = engine.windowInfo();
        const pixels: render3d.Extent2D = if (info) |i|
            .{ .width = i.pixel_size.width, .height = i.pixel_size.height }
        else
            .{ .width = self.settings.width, .height = self.settings.height };
        if (pixels.isEmpty()) return false;

        try self.world.begin(.{
            .camera = .{
                .position = eye,
                .rotation = Quat.lookRotation(Vec3.zero.sub(eye), Vec3.up).?,
                .vertical_fov = std.math.pi / 3.2,
                .near = 0.1,
                .far = 50,
            },
            .target_size = pixels,
            .clear_color = self.settings.clear_linear,
        });
        try self.world.drawMesh(.{
            .mesh = self.floor,
            .world = Mat4.trs(.init(0, -0.1, 0), Quat.fromAxisAngle(.init(0, 0, 1), 0.2), .one),
        });
        try self.world.drawMesh(.{
            .mesh = self.cube,
            .world = Mat4.fromQuat(Quat.fromAxisAngle(cube_axis.normalize(), self.cube_angle)),
        });
        try self.world.drawMesh(.{
            .mesh = self.slab,
            .world = Mat4.fromQuat(Quat.fromAxisAngle(slab_axis.normalize(), self.slab_angle)),
        });

        if (!overlay_on) {
            try engine.renderScene(.{}, &self.world, null);
            return true;
        }
        try self.describeOverlay(engine, info);
        try engine.renderScene(.{}, &self.world, &self.overlay);
        return true;
    }

    fn describeOverlay(self: *Sample, engine: *app.Engine, info: ?platform.WindowInfo) !void {
        const logical = if (info) |i| i.logical_size else platform.Size{ .width = self.settings.width, .height = self.settings.height };
        try self.overlay.begin(.{
            .camera = .{ .viewport = .init(0, 0, @floatFromInt(logical.width), @floatFromInt(logical.height)) },
            .pixel_scale = if (info) |i| i.scale else 1,
        });
        try self.overlay.setView(.screen);

        const payload = engine.assets.payloadOf(self.font_asset) orelse return;
        const glyphs = self.overlay.textureRegion(payload.asHandle(render2d.TextureHandle)) orelse return;
        const font: render2d.BitmapFont = .{
            .glyphs = glyphs,
            .cell = .{ .width = 8, .height = 8 },
            .columns = 16,
            .glyph_count = 95,
        };

        // The previous frame's time: this one is not over yet.
        const last_ms = if (engine.profiler()) |recorder|
            if (recorder.latest()) |frame| ms(frame.total_ns) else 0
        else
            0;
        var buffer: [96]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "{s}  {d}x MSAA  {d:.2} ms", .{
            app.graphics_backend, self.sample_count, last_ms,
        }) catch buffer[0..0];
        try self.overlay.drawText(font, line, .{ .position = .init(12, 12), .scale = 2 });
    }

    fn deinit(self: *Sample, engine: *app.Engine) void {
        if (!self.font_asset.isNone()) engine.assets.release(self.font_asset);
        _ = engine.assets.unregisterLoader(self.gpa, asset.schemas.texture.id);
        self.world.destroyMesh(self.floor);
        self.world.destroyMesh(self.slab);
        self.world.destroyMesh(self.cube);
        self.overlay.deinit();
        self.world.deinit();
    }
};

// ---------------------------------------------------------------------------------------
// The meshes, built here because nothing imports one yet (`render3d.md` §8).

/// Linear RGBA8, one per face: +X, −X, +Y, −Y, +Z, −Z.
const Faces = [6][4]u8;

const cube_faces: Faces = .{
    .{ 200, 60, 30, 255 },
    .{ 120, 30, 15, 255 },
    .{ 230, 170, 40, 255 },
    .{ 90, 60, 10, 255 },
    .{ 180, 90, 40, 255 },
    .{ 150, 45, 25, 255 },
};

const slab_faces: Faces = .{
    .{ 20, 110, 190, 255 },
    .{ 15, 70, 140, 255 },
    .{ 40, 170, 230, 255 },
    .{ 10, 40, 90, 255 },
    .{ 25, 130, 210, 255 },
    .{ 20, 90, 170, 255 },
};

/// Each face's outward normal and two edges whose cross product is that normal, so its
/// corners, taken in order, are counter-clockwise seen from outside: the pipeline's front.
const face_frames = [6][3]Vec3{
    .{ .init(1, 0, 0), .init(0, 0, -1), .init(0, 1, 0) },
    .{ .init(-1, 0, 0), .init(0, 0, 1), .init(0, 1, 0) },
    .{ .init(0, 1, 0), .init(1, 0, 0), .init(0, 0, -1) },
    .{ .init(0, -1, 0), .init(1, 0, 0), .init(0, 0, 1) },
    .{ .init(0, 0, 1), .init(1, 0, 0), .init(0, 1, 0) },
    .{ .init(0, 0, -1), .init(-1, 0, 0), .init(0, 1, 0) },
};

fn createBox(world: *render3d.Renderer, half: Vec3, faces: Faces, label: []const u8) !render3d.MeshHandle {
    var positions: [24]Vec3 = undefined;
    var colours: [24][4]u8 = undefined;
    var indices: [36]u16 = undefined;
    for (face_frames, faces, 0..) |frame, colour, f| {
        const n = scaled(frame[0], half);
        const u = scaled(frame[1], half);
        const v = scaled(frame[2], half);
        const base: u16 = @intCast(f * 4);
        positions[base + 0] = n.sub(u).sub(v);
        positions[base + 1] = n.add(u).sub(v);
        positions[base + 2] = n.add(u).add(v);
        positions[base + 3] = n.sub(u).add(v);
        for (colours[base..][0..4]) |*c| c.* = colour;
        indices[f * 6 ..][0..6].* = .{ base, base + 1, base + 2, base, base + 2, base + 3 };
    }
    return createMesh(world, &positions, &colours, &indices, label);
}

fn scaled(v: Vec3, by: Vec3) Vec3 {
    return .init(v.x * by.x, v.y * by.y, v.z * by.z);
}

/// A single-sided square facing +Y, in two tones so its tilt reads.
fn createFloor(world: *render3d.Renderer) !render3d.MeshHandle {
    const h: f32 = 1.9;
    const positions = [_]Vec3{
        .init(-h, 0, h), .init(h, 0, h), .init(h, 0, -h), .init(-h, 0, -h),
    };
    const near: [4]u8 = .{ 70, 90, 60, 255 };
    const far: [4]u8 = .{ 30, 45, 35, 255 };
    const colours = [_][4]u8{ near, near, far, far };
    const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };
    return createMesh(world, &positions, &colours, &indices, "sandbox3d floor");
}

fn createMesh(
    world: *render3d.Renderer,
    positions: []const Vec3,
    colours: []const [4]u8,
    indices: []const u16,
    label: []const u8,
) !render3d.MeshHandle {
    const submeshes = [_]asset.Submesh{.{ .first_index = 0, .index_count = @intCast(indices.len) }};
    const streams = [_]asset.MeshStream{
        .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(positions) },
        .{ .semantic = .color, .format = .unorm8x4, .bytes = std.mem.sliceAsBytes(colours) },
    };
    return world.createMesh(.{
        .vertex_count = @intCast(positions.len),
        .streams = &streams,
        .index_format = .uint16,
        .indices = std.mem.sliceAsBytes(indices),
        .submeshes = &submeshes,
        .bounds = try asset.Mesh.computeBounds(positions),
    }, label);
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "a box's faces all wind counter-clockwise seen from outside" {
    for (face_frames) |frame| {
        const n = frame[0];
        const u = frame[1];
        const v = frame[2];
        try testing.expect(Vec3.cross(u, v).sub(n).length() < 1e-6);
    }
}

test "only --msaa=1 and --msaa=4 are accepted" {
    try testing.expectEqual(@as(?u32, 1), parseMsaa("--msaa=1"));
    try testing.expectEqual(@as(?u32, 4), parseMsaa("--msaa=4"));
    try testing.expectEqual(@as(?u32, null), parseMsaa("--msaa=2"));
    try testing.expectEqual(@as(?u32, null), parseMsaa("--msaa"));
}
