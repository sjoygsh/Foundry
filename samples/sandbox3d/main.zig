//! `samples/sandbox3d` — the sample that gains each 3D capability from M19 to M25, as
//! `samples/sandbox` gained 2D's (`docs/design/render3d.md` §8).
//!
//! **M19's capability was depth**: meshes built here that pass through each other, and one line
//! of `render2d` text over them, the first proof that 2D draws over a 3D frame.
//!
//! **M20's is meshes from content** (`docs/design/meshes.md` §9). The room is `models/room.gltf`
//! and the crates are `models/crate.gltf`, compiled by the package compiler into records and
//! drawn by content ID through `render3d.Content`. Nothing here knows they were glTF. The room
//! has a node hierarchy, a mirrored crate, an alpha-masked plant and a glass pane that blends. A
//! grid of crates stands outside the walls, most of it culled at any moment, and one crate draws
//! with a slot override. M19's cube still spins on the table, built here with a material made in
//! code, so the code path and the content path draw side by side.
//!
//! **This module is not given `rhi`** (`build.zig`), so reaching for a device, a pipeline or a
//! texture format here is a build error, not a review finding (CLAUDE.md §4.2). It reaches the
//! GPU only through `render3d`, `render2d` and `app.Engine.renderScene`.
//!
//! What it is told — window, clear colour, spin rates, font — is its package's
//! `sandbox3d:config` record, loaded through the path every package takes (I3). `--msaa=1|4`
//! and `--cull=on|off` are host bootstrap (ADR-0031), there so the same frame can be shown both
//! ways; culling changes no pixel, only the counts and the time.
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
    var options: Options = .{};
    while (arguments.next()) |arg| {
        if (!options.parse(arg)) {
            var buffer: [256]u8 = undefined;
            var err = std.Io.File.stderr().writer(init.io, &buffer);
            err.interface.writeAll("usage: sandbox3d [--msaa=1|4] [--cull=on|off]\n") catch {};
            err.interface.flush() catch {};
            // A mistyped command line is the operator's to fix, not a crash to trace.
            std.process.exit(2);
        }
    }

    const env = try app.environment(gpa, init);
    defer gpa.free(env);
    try run(gpa, env, options);
}

/// The command line: bootstrap for the evidence, never a game setting.
const Options = struct {
    sample_count: u32 = 4,
    cull: bool = true,

    /// False for anything this sample does not take.
    fn parse(self: *Options, arg: []const u8) bool {
        if (std.mem.eql(u8, arg, "--msaa=1")) {
            self.sample_count = 1;
        } else if (std.mem.eql(u8, arg, "--msaa=4")) {
            self.sample_count = 4;
        } else if (std.mem.eql(u8, arg, "--cull=on")) {
            self.cull = true;
        } else if (std.mem.eql(u8, arg, "--cull=off")) {
            self.cull = false;
        } else return false;
        return true;
    }
};

fn run(gpa: std.mem.Allocator, env: []const platform.os.EnvVar, options: Options) !void {
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
            // Deliberately not the package's title: the one a player sees arrives from
            // content through `setWindowTitle`, so a wrong title shows that path failed.
            .title = "sandbox3d",
            .logical_width = 1280,
            .logical_height = 720,
            .surface = app.window_surface,
        },
        .content_dir = content_dir,
        .content = packages,
    });
    defer engine.deinit();

    var sample = try Sample.init(gpa, engine, options);
    defer sample.deinit(engine);
    try sample.load(engine);

    const overlay_on = if (engine.os.envVar("FOUNDRY_SANDBOX3D_OVERLAY")) |v| !std.mem.eql(u8, v, "0") else true;
    const frame_limit = frameLimit(engine, headless);
    log.info("{s} backend, {d}x MSAA, culling {s}, overlay {s}{s}", .{
        app.graphics_backend,
        options.sample_count,
        if (options.cull) "on" else "off",
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
    log.info("stopped after {d} frames ({d} skipped), {d} ticks; last frame {d} draws, {d} culled, {d} blended, {d} triangles", .{
        engine.frame_index, skipped_frames, engine.stepper.tick, stats.draws, stats.culled, stats.blended, stats.triangles,
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
    orbit_radians_per_second: f32,
    orbit_radius: f32,
    orbit_height: f32,
    font: core.ContentId,
    room: core.ContentId,
    crate: core.ContentId,
    crate_override: core.ContentId,
    grid: Grid,

    const fallback: Settings = .{
        .title = "",
        .width = 1280,
        .height = 720,
        .clear_linear = .{ 0, 0, 0, 1 },
        .cube_radians_per_second = 0,
        .orbit_radians_per_second = 0,
        .orbit_radius = 7.5,
        .orbit_height = 5,
        .font = .none,
        .room = .none,
        .crate = .none,
        .crate_override = .none,
        .grid = .{ .side = 0, .spacing = 0, .clearance = 0 },
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
            .orbit_radians_per_second = rateField(record, "orbit_radians_per_second") orelse 0,
            .orbit_radius = distanceField(record, "orbit_radius", 1, 100) orelse fallback.orbit_radius,
            .orbit_height = distanceField(record, "orbit_height", -100, 100) orelse fallback.orbit_height,
            .font = idField(record, "font") orelse .none,
            .room = idField(record, "room") orelse .none,
            .crate = idField(record, "crate") orelse .none,
            .crate_override = idField(record, "crate_override") orelse .none,
            .grid = .{
                .side = gridField(record) orelse 0,
                .spacing = distanceField(record, "crate_spacing", 0.5, 100) orelse 0,
                .clearance = distanceField(record, "crate_clearance", 0, 100) orelse 0,
            },
        };
    }

    /// Finite metres inside `[min, max]`.
    fn distanceField(record: data.store.Record, name: []const u8, min: f64, max: f64) ?f32 {
        const index = record.schema.fieldIndex(name) orelse return null;
        const value = (record.fields.floatAt(index) catch null) orelse return null;
        if (!std.math.isFinite(value) or value < min or value > max) {
            log.warn("'{s}' is not a distance in [{d}, {d}] metres; using the fallback", .{ name, min, max });
            return null;
        }
        return @floatCast(value);
    }

    /// Bounded, because every crate is a draw each frame.
    fn gridField(record: data.store.Record) ?u32 {
        const index = record.schema.fieldIndex("crate_grid") orelse return null;
        const value = (record.fields.intAt(index) catch null) orelse return null;
        if (value < 0 or value > Grid.max_side) {
            log.warn("'crate_grid' = {d} is not a side from 0 to {d}; no crates", .{ value, Grid.max_side });
            return null;
        }
        return @intCast(value);
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

/// Where the crates stand: a square of cells centred on the origin, less those within
/// `clearance` of it on both axes, which is inside the room. Iterated in a fixed order, so
/// which crate is first, and wears the override, is the same on every run (I9).
const Grid = struct {
    side: u32,
    spacing: f32,
    clearance: f32,

    const max_side = 32;

    const Cell = struct { position: Vec3, turn: f32 };

    fn cell(self: Grid, i: u32) ?Cell {
        const col = i % self.side;
        const row = i / self.side;
        const middle = @as(f32, @floatFromInt(self.side - 1)) / 2;
        const x = (@as(f32, @floatFromInt(col)) - middle) * self.spacing;
        const z = (@as(f32, @floatFromInt(row)) - middle) * self.spacing;
        if (@abs(x) < self.clearance and @abs(z) < self.clearance) return null;
        // An eighth of a turn at a time, varied by cell, so the grid does not read as a stamp.
        const turn = @as(f32, @floatFromInt((col * 7 + row * 3) % 8)) * (std.math.pi / 8.0);
        return .{ .position = .init(x, 0, z), .turn = turn };
    }

    fn cells(self: Grid) u32 {
        return self.side * self.side;
    }
};

// ---------------------------------------------------------------------------------------
// The sample.

const Sample = struct {
    gpa: std.mem.Allocator,
    sample_count: u32,
    world: render3d.Renderer,
    overlay: render2d.Renderer,
    /// Created in `load`, once `world` is at its final address, because it borrows it.
    content: ?render3d.Content = null,

    cube: render3d.MeshHandle,
    cube_material: render3d.MaterialHandle,

    room: render3d.ModelHandle = .none,
    crate: render3d.ModelHandle = .none,
    crate_override: render3d.MaterialHandle = .none,

    settings: Settings = Settings.fallback,
    content_generation: u64 = 0,
    font_asset: asset.AssetHandle = .none,
    /// A model draw that failed is said once, not every frame.
    reported: bool = false,

    /// The cube's turn and the camera's place on its circle, advanced by whole simulation
    /// steps (I9).
    cube_angle: f32 = 0,
    orbit_angle: f32 = 0,

    const cube_axis: Vec3 = .init(0.3, 1, 0.2);
    /// On the table: its top is at 0.78 m, and the turning cube's corners reach 0.26 m out.
    const cube_place: Vec3 = .init(0, 1.05, 0);
    const cube_scale: f32 = 0.25;
    /// What the camera looks at: the table, a little below its top.
    const focus: Vec3 = .init(0, 0.6, 0);

    fn init(gpa: std.mem.Allocator, engine: *app.Engine, options: Options) !Sample {
        var world = try render3d.Renderer.init(gpa, engine.gpu, .{ .sample_count = options.sample_count, .cull = options.cull });
        errdefer world.deinit();
        var overlay = try render2d.Renderer.init(gpa, engine.gpu, .{ .jobs = engine.jobs() });
        errdefer overlay.deinit();

        const cube_material = try world.createMaterial(.{}, "sandbox3d cube");
        errdefer world.destroyMaterial(cube_material);
        const cube = try createBox(&world, .init(0.6, 0.6, 0.6), cube_faces, "sandbox3d cube");

        return .{
            .gpa = gpa,
            .sample_count = options.sample_count,
            .world = world,
            .overlay = overlay,
            .cube = cube,
            .cube_material = cube_material,
        };
    }

    /// The texture loader and `Content` both borrow the renderers, so this waits until the
    /// sample has reached its final address.
    fn load(self: *Sample, engine: *app.Engine) !void {
        try engine.assets.registerLoader(self.gpa, render2d.textureLoader(&self.overlay));
        self.content = render3d.Content.init(self.gpa, &self.world, &engine.assets, .default);
        self.refresh(engine);
    }

    /// Everything derived from content, derived again whenever content changes.
    fn refresh(self: *Sample, engine: *app.Engine) void {
        const before = self.settings;
        const first = self.content_generation == 0 and self.room.isNone() and self.crate.isNone();
        self.settings = Settings.read(engine);
        self.content_generation = engine.contentGeneration();
        self.reported = false;

        if (self.settings.title.len != 0) {
            engine.setWindowTitle(self.settings.title) catch |err|
                log.warn("the window title from '{s}' was refused ({t})", .{ config_id, err });
        }
        if (self.settings.width != before.width or self.settings.height != before.height) {
            engine.setWindowSize(.{ .width = self.settings.width, .height = self.settings.height }) catch |err|
                log.warn("the window size from '{s}' was refused ({t})", .{ config_id, err });
        }

        // Records and assets that changed underneath the handles already held. What the
        // config names is settled after, so a model named for the first time is read fresh.
        if (!first) {
            if (self.content) |*content| content.contentChanged() catch |err|
                log.warn("the scene could not follow a content change ({t}); drawing what it had", .{err});
        }
        self.room = self.follow(self.room, before.room, self.settings.room, first);
        self.crate = self.follow(self.crate, before.crate, self.settings.crate, first);
        self.crate_override = self.followMaterial(before.crate_override, first);

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

    /// The model `id` names now: the one already held if the name did not change, else a fresh
    /// one, with the old released. A model that will not resolve is logged and not drawn.
    fn follow(self: *Sample, held: render3d.ModelHandle, was: core.ContentId, id: core.ContentId, first: bool) render3d.ModelHandle {
        const content = &(self.content orelse return held);
        if (!first and was.eql(id) and !held.isNone()) return held;
        if (!held.isNone()) content.releaseModel(held);
        if (id.eql(.none)) return .none;
        return content.acquireModel(id) catch |err| {
            log.warn("model {f} is not drawn ({t})", .{ id, err });
            return .none;
        };
    }

    fn followMaterial(self: *Sample, was: core.ContentId, first: bool) render3d.MaterialHandle {
        const content = &(self.content orelse return self.crate_override);
        const id = self.settings.crate_override;
        if (!first and was.eql(id) and !self.crate_override.isNone()) return self.crate_override;
        if (!self.crate_override.isNone()) content.releaseMaterial(self.crate_override);
        if (id.eql(.none)) return .none;
        return content.acquireMaterial(id) catch |err| {
            log.warn("material {f} is not used ({t})", .{ id, err });
            return .none;
        };
    }

    fn step(self: *Sample, s: app.Step) void {
        const dt = s.delta.toSecondsF32();
        self.cube_angle = wrap(self.cube_angle + self.settings.cube_radians_per_second * dt);
        self.orbit_angle = wrap(self.orbit_angle + self.settings.orbit_radians_per_second * dt);
    }

    fn wrap(angle: f32) f32 {
        return @mod(angle, 2 * std.math.pi);
    }

    fn eye(self: *const Sample) Vec3 {
        const r = self.settings.orbit_radius;
        return .init(r * @cos(self.orbit_angle), self.settings.orbit_height, r * @sin(self.orbit_angle));
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

        const position = self.eye();
        try self.world.begin(.{
            .camera = .{
                .position = position,
                .rotation = Quat.lookRotation(focus.sub(position), Vec3.up) orelse Quat.identity,
                .vertical_fov = std.math.pi / 3.2,
                .near = 0.1,
                .far = 80,
            },
            .target_size = pixels,
            .clear_color = self.settings.clear_linear,
        });

        self.drawModel(.{ .model = self.room, .world = Mat4.identity });
        const override = [_]render3d.SlotOverride{.{ .slot = 0, .material = self.crate_override }};
        var placed: u32 = 0;
        const grid = self.settings.grid;
        for (0..grid.cells()) |i| {
            const cell = grid.cell(@intCast(i)) orelse continue;
            self.drawModel(.{
                .model = self.crate,
                .world = Mat4.trs(cell.position, Quat.fromAxisAngle(Vec3.up, cell.turn), .one),
                // The first crate of the grid, and only it, wears the override.
                .overrides = if (placed == 0 and !self.crate_override.isNone()) &override else &.{},
            });
            placed += 1;
        }

        try self.world.drawMesh(.{
            .mesh = self.cube,
            .material = self.cube_material,
            .world = Mat4.trs(cube_place, Quat.fromAxisAngle(cube_axis.normalize(), self.cube_angle), .init(cube_scale, cube_scale, cube_scale)),
        });

        if (!overlay_on) {
            try engine.renderScene(.{}, &self.world, null);
            return true;
        }
        try self.describeOverlay(engine, info);
        try engine.renderScene(.{}, &self.world, &self.overlay);
        return true;
    }

    /// A model that cannot be drawn this frame is skipped and said once; the frame goes on.
    fn drawModel(self: *Sample, model_draw: render3d.ModelDraw) void {
        if (model_draw.model.isNone()) return;
        const content = &(self.content orelse return);
        content.drawModel(model_draw) catch |err| {
            if (!self.reported) log.warn("a model draw was refused ({t}); skipping it", .{err});
            self.reported = true;
        };
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

        // The previous frame's time and counts: this one is not over yet.
        const last_ms = if (engine.profiler()) |recorder|
            if (recorder.latest()) |frame| ms(frame.total_ns) else 0
        else
            0;
        const stats = self.world.frameStats();
        var buffer: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "{s}  {d}x MSAA  {d} draws  {d} culled  {d} blended  {d:.2} ms", .{
            app.graphics_backend, self.sample_count, stats.draws, stats.culled, stats.blended, last_ms,
        }) catch buffer[0..0];
        try self.overlay.drawText(font, line, .{ .position = .init(12, 12), .scale = 2 });
    }

    fn deinit(self: *Sample, engine: *app.Engine) void {
        if (!self.font_asset.isNone()) engine.assets.release(self.font_asset);
        // Before the renderer it borrows: its materials go first, then the meshes and
        // textures its loaders made.
        if (self.content) |*content| content.deinit();
        _ = engine.assets.unregisterLoader(self.gpa, asset.schemas.texture.id);
        self.world.destroyMesh(self.cube);
        self.world.destroyMaterial(self.cube_material);
        self.overlay.deinit();
        self.world.deinit();
    }
};

// ---------------------------------------------------------------------------------------
// The cube, built here so that one mesh on screen still comes from code (`meshes.md` §9).

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

test "only --msaa=1|4 and --cull=on|off are accepted, and the last one given wins" {
    var options: Options = .{};
    try testing.expectEqual(@as(u32, 4), options.sample_count);
    try testing.expect(options.cull);
    try testing.expect(options.parse("--msaa=1"));
    try testing.expect(options.parse("--cull=off"));
    try testing.expectEqual(@as(u32, 1), options.sample_count);
    try testing.expect(!options.cull);
    try testing.expect(options.parse("--cull=on"));
    try testing.expect(options.cull);
    for ([_][]const u8{ "--msaa=2", "--msaa", "--cull", "--cull=yes", "--cull=OFF" }) |bad| {
        try testing.expect(!options.parse(bad));
    }
}

test "the crate grid leaves the room's cells empty, and places the rest in a fixed order" {
    const grid: Grid = .{ .side = 9, .spacing = 2.4, .clearance = 3.5 };
    var placed: u32 = 0;
    var first: ?Grid.Cell = null;
    for (0..grid.cells()) |i| {
        const cell = grid.cell(@intCast(i)) orelse continue;
        try testing.expect(@abs(cell.position.x) >= 3.5 or @abs(cell.position.z) >= 3.5);
        if (first == null) first = cell;
        placed += 1;
    }
    // Nine to a side, less the three by three that 0 and ±2.4 make inside ±3.5.
    try testing.expectEqual(@as(u32, 81 - 9), placed);
    try testing.expectEqual(@as(f32, -9.6), first.?.position.x);
    try testing.expectEqual(@as(f32, -9.6), first.?.position.z);

    const empty: Grid = .{ .side = 0, .spacing = 2.4, .clearance = 3.5 };
    try testing.expectEqual(@as(u32, 0), empty.cells());
    const one: Grid = .{ .side = 1, .spacing = 2.4, .clearance = 0 };
    try testing.expectEqual(Vec3.zero, one.cell(0).?.position);
}
