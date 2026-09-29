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
//! **M21's is nested moving objects** (`docs/design/hierarchy.md` §8). An orrery on the table,
//! and a frame scaled `(2, 1, 1)` carrying a child turned 45°, live in a `scene.World` with the
//! engine's transform hierarchy (`orrery.zig`). Each is a template in the package; the parents
//! are set in code. After the steps the sample reads each `sandbox3d:model`'s world pose and
//! draws it; the cube's pose is an entity's too. The debug overlay inspects the world live:
//! - **F1** shows or hides it, with the entity tree, the profiler and the log;
//! - **F5** saves the world to the user data directory and **F9** loads it back, logging a hash
//!   of every world pose on both sides so a person can see they are the same;
//! - **F6** moves the orbiting crate between the riding crate and the cube, keeping its world
//!   pose, and logs how far it did not move;
//! - **F7** tries the same for the sheared child, which is refused as `NotRepresentable`.
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
//! - `FOUNDRY_SANDBOX3D_WORKERS=n` sets the engine's worker count;
//! - `FOUNDRY_SANDBOX3D_PANELS=1` starts with the debug overlay shown;
//! - `FOUNDRY_SANDBOX3D_SAVE_DIR=path` redirects F5/F9 for a disposable evidence run;
//! - `FOUNDRY_SANDBOX3D_KEYS=f5@120,f6@150,...` presses those keys on those frames, as if a
//!   person had, so a run nobody watches still saves, loads and re-parents.

const std = @import("std");

const app = @import("app");
const asset = @import("asset");
const core = @import("core");
const data = @import("data");
const debug = @import("debug");
const platform = @import("platform");
const render2d = @import("render2d");
const render3d = @import("render3d");
const scene = @import("scene");
const ui = @import("ui");

const orrery_mod = @import("orrery.zig");
const Orrery = orrery_mod.Orrery;

const Mat4 = core.math.Mat4;
const Quat = core.math.Quat;
const Vec3 = core.math.Vec3;

const log = core.log.scoped(.sandbox3d);

pub const std_options = app.std_options;

const app_name = "foundry-sandbox3d";
const config_id = "sandbox3d:config.main";
const default_headless_frames: u64 = 120;
/// The save F5 writes and F9 reads, in the user data directory.
const save_name = "world.fsav";

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
        // Info, in every build, so the overlay's log shows what F5, F9, F6 and F7 did.
        .log_capture = .info,
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

    var script = Script.fromEnv(engine);
    var skipped_frames: u64 = 0;
    while (!engine.shouldQuit()) {
        engine.beginFrame();
        if (sample.content_generation != engine.contentGeneration()) sample.refresh(engine);

        // Drained so the window keeps answering; the engine acts on a close itself. Text is
        // kept for the overlay's filter box.
        sample.typed_len = 0;
        while (engine.nextEvent()) |ev| sample.noteEvent(ev);
        // **The overlay first, before a key is read**, so a key the filter box took is not
        // also a command (`ui.md` step 6).
        try sample.describeUi(engine);
        if (engine.input.wasPressed(.escape)) engine.requestQuit();
        sample.keys(engine, script.pressed(engine.frame_index));
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

    /// The camera's place on its circle, advanced by whole simulation steps (I9).
    orbit_angle: f32 = 0,

    /// The nested moving objects. On the heap, because its world borrows its registry and
    /// this struct is returned by value.
    orrery: *Orrery,
    /// The models the orrery's entities name, acquired the first time one is drawn. Few, so
    /// a list; released whenever content changes, so a renamed record is followed.
    models: std.ArrayList(struct { id: core.ContentId, handle: render3d.ModelHandle }) = .empty,
    /// The confined root where F5 and F9 keep the world. Null when the platform has no user
    /// data directory.
    save_dir: ?[]u8 = null,

    /// The debug overlay's kernel and its panels (ADR-0025), hosted as `samples/room` hosts
    /// them. The panels are heap-allocated because the built-in ones point into the struct.
    ui: ui.Context,
    panels: *debug.Overlay,
    panels_open: bool = false,
    /// The poses F5 last saved, so F9 can say whether it brought back the same ones.
    saved_hash: ?u64 = null,
    typed: [8]platform.event.TextInput = undefined,
    typed_len: usize = 0,

    /// What the camera looks at: the table's top, where the orrery stands.
    const focus: Vec3 = .init(0, 0.8, 0);

    fn init(gpa: std.mem.Allocator, engine: *app.Engine, options: Options) !Sample {
        var world = try render3d.Renderer.init(gpa, engine.gpu, .{ .sample_count = options.sample_count, .cull = options.cull });
        errdefer world.deinit();
        var overlay = try render2d.Renderer.init(gpa, engine.gpu, .{ .jobs = engine.jobs() });
        errdefer overlay.deinit();

        const cube_material = try world.createMaterial(.{}, "sandbox3d cube");
        errdefer world.destroyMaterial(cube_material);
        const cube = try createBox(&world, .init(0.6, 0.6, 0.6), cube_faces, "sandbox3d cube");
        errdefer world.destroyMesh(cube);

        const orrery = try gpa.create(Orrery);
        errdefer gpa.destroy(orrery);
        try orrery.init(gpa, engine.jobs());
        errdefer orrery.deinit();
        // Wider than the default column, because the tree's rows are indented.
        const panels = try debug.Overlay.init(gpa, .{ .panel_width = panel_width });
        errdefer panels.deinit();

        return .{
            .gpa = gpa,
            .sample_count = options.sample_count,
            .world = world,
            .overlay = overlay,
            .cube = cube,
            .cube_material = cube_material,
            .orrery = orrery,
            .ui = .init(gpa, overlayStyle(.{ .font = placeholderFont() })),
            .panels = panels,
        };
    }

    /// The texture loader and `Content` both borrow the renderers, so this waits until the
    /// sample has reached its final address.
    fn load(self: *Sample, engine: *app.Engine) !void {
        try engine.assets.registerLoader(self.gpa, render2d.textureLoader(&self.overlay));
        self.content = render3d.Content.init(self.gpa, &self.world, &engine.assets, .default);
        self.refresh(engine);

        self.orrery.populate(&engine.store);
        self.save_dir = saveDir(self.gpa, engine);
        // The entity tree and the log, which says what each key did, with the sheared child
        // selected, so opening the overlay shows 3d.md §7.1's distinction without a click.
        // The profiler, which opens by default, is one click away in the bar: three panels in
        // one column leave the selection no room.
        self.panels.toggle("profiler");
        self.panels.toggle("entities");
        self.panels.toggle("log");
        self.panels.entities.selected = self.orrery.role(.sheared);
        self.panels_open = engine.os.envVar("FOUNDRY_SANDBOX3D_PANELS") != null;
        log.info("keys: f1 overlay, f5 save, f9 load, f6 move the orbiting crate, f7 try the sheared one, escape quit", .{});
    }

    /// The user data directory, made if it is not there yet. The file beneath it is opened
    /// confined and never by joining this capability to an unchecked path.
    fn saveDir(gpa: std.mem.Allocator, engine: *app.Engine) ?[]u8 {
        const dir = if (engine.os.envVar("FOUNDRY_SANDBOX3D_SAVE_DIR")) |override|
            gpa.dupe(u8, override) catch return null
        else
            engine.os.userDataDirAlloc(gpa) catch |err| {
                log.warn("no user data directory ({t}); f5 and f9 do nothing", .{err});
                return null;
            };
        engine.os.createDirPath(dir) catch |err| {
            log.warn("the user data directory could not be made ({t}); f5 and f9 do nothing", .{err});
            gpa.free(dir);
            return null;
        };
        return dir;
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
            self.releaseModels();
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
        self.orbit_angle = wrap(self.orbit_angle + self.settings.orbit_radians_per_second * dt);
        // The game translates `app`'s step into `scene`'s tick: the number and the fixed
        // delta, and nothing a system could read a device through.
        self.orrery.step(.{ .tick = s.tick, .delta = s.delta });
    }

    fn noteEvent(self: *Sample, ev: platform.Event) void {
        switch (ev) {
            .text_input => |typed| {
                if (self.typed_len == self.typed.len) return;
                self.typed[self.typed_len] = typed;
                self.typed_len += 1;
            },
            else => {},
        }
    }

    /// The overlay's kernel, described at the top of the frame. Drawn in `describeOverlay`.
    fn describeUi(self: *Sample, engine: *app.Engine) !void {
        if (!self.panels_open) return;
        const info = engine.windowInfo();
        const width: f32 = if (info) |i| @floatFromInt(i.logical_size.width) else @floatFromInt(self.settings.width);
        const height: f32 = if (info) |i| @floatFromInt(i.logical_size.height) else @floatFromInt(self.settings.height);
        self.ui.style = overlayStyle(self.uiFont(engine));
        self.ui.begin(.{
            .keys = engine.input,
            .pointer = engine.input.mouse.position,
            .wheel = engine.input.mouse.wheel,
            .text = self.typed[0..self.typed_len],
            .frame = engine.frame_index,
        }, .init(0, 0, width, height));
        defer self.ui.end();
        // The world and both renderers are the game's, so the game hands them over.
        try self.panels.describe(&self.ui, engine, .{
            .world = &self.orrery.world,
            .renderer = &self.overlay,
            .world3d = &self.world,
        });
    }

    /// The keys, pressed by a person or by `FOUNDRY_SANDBOX3D_KEYS`. None of them is a letter
    /// a text field types, so they stay live while the overlay's filter box has focus.
    fn keys(self: *Sample, engine: *app.Engine, scripted: Script.Keys) void {
        const in = &engine.input;
        if (in.wasPressed(.f1) or scripted.f1) {
            self.panels_open = !self.panels_open;
            log.info("debug overlay {s}", .{if (self.panels_open) "shown" else "hidden"});
        }
        if (in.wasPressed(.f5) or scripted.f5) self.saveWorld(engine);
        if (in.wasPressed(.f9) or scripted.f9) self.loadWorld(engine);
        if (in.wasPressed(.f6) or scripted.f6) {
            if (self.orrery.hopMoon()) |hop| {
                const from = hop.from orelse scene.Entity.none;
                log.info("f6: the orbiting crate moved from #{d}.{d} to #{d}.{d}, keeping its world pose (largest change {e:.2})", .{
                    from.index, from.generation, hop.to.index, hop.to.generation, hop.moved,
                });
            } else |err| log.warn("f6: the orbiting crate could not move ({t})", .{err});
        }
        if (in.wasPressed(.f7) or scripted.f7) {
            const before = self.orrery.poseHash();
            if (self.orrery.hopSheared()) |hop| {
                log.warn("f7: the sheared crate moved to #{d}.{d}, which 3d.md §7.1 says it cannot", .{ hop.to.index, hop.to.generation });
            } else |err| log.info("f7: the sheared crate cannot keep its world pose on the turntable ({t}); poses {s}", .{
                err, if (before == self.orrery.poseHash()) "unchanged" else "CHANGED",
            });
        }
    }

    fn saveWorld(self: *Sample, engine: *app.Engine) void {
        const dir = self.save_dir orelse return;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.gpa);
        const hash = self.orrery.save(&bytes) catch |err| {
            log.warn("f5: the world could not be saved ({t})", .{err});
            return;
        };
        _ = engine.os.replaceFileConfined(dir, save_name, bytes.items, orrery_mod.max_save_bytes) catch |err| {
            log.warn("f5: the save could not be written ({t})", .{err});
            return;
        };
        self.saved_hash = hash;
        // The path is the user's home directory, and a log is something people paste.
        log.info("f5: saved {d} entities ({d} bytes) to the user data directory; poses {x:0>16}", .{
            self.orrery.world.entityCount(), bytes.items.len, hash,
        });
    }

    fn loadWorld(self: *Sample, engine: *app.Engine) void {
        const dir = self.save_dir orelse return;
        const read = engine.os.readFileConfined(self.gpa, dir, save_name, orrery_mod.max_save_bytes) catch |err| {
            log.warn("f9: no save to load ({t})", .{err});
            return;
        };
        defer self.gpa.free(read.bytes);
        const hash = self.orrery.load(read.bytes, &engine.store) orelse return;
        // The selection was the old world's handle; the save carried the same one.
        self.panels.entities.selected = self.orrery.role(.sheared);
        const same = if (self.saved_hash) |saved| (if (saved == hash) ", the same as this run's save" else ", not this run's save") else "";
        log.info("f9: poses {x:0>16}{s}", .{ hash, same });
    }

    fn uiFont(self: *Sample, engine: *app.Engine) app.UiFont {
        var font = placeholderFont();
        if (engine.assets.payloadOf(self.font_asset)) |payload| {
            if (self.overlay.textureRegion(payload.asHandle(render2d.TextureHandle))) |glyphs| font.glyphs = glyphs;
        }
        return .{ .font = font };
    }

    /// The model `id` names, acquired once and kept until content changes. One that will not
    /// resolve is remembered as `.none`, so it is said once rather than every frame.
    fn modelFor(self: *Sample, id: core.ContentId) render3d.ModelHandle {
        for (self.models.items) |m| {
            if (m.id.eql(id)) return m.handle;
        }
        const content = &(self.content orelse return .none);
        const handle = content.acquireModel(id) catch |err| blk: {
            log.warn("model {f} is not drawn ({t})", .{ id, err });
            break :blk render3d.ModelHandle.none;
        };
        self.models.append(self.gpa, .{ .id = id, .handle = handle }) catch {
            if (!handle.isNone()) content.releaseModel(handle);
            return .none;
        };
        return handle;
    }

    fn releaseModels(self: *Sample) void {
        if (self.content) |*content| {
            for (self.models.items) |m| {
                if (!m.handle.isNone()) content.releaseModel(m.handle);
            }
        }
        self.models.clearRetainingCapacity();
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

        // **Extraction** (`hierarchy.md` §8): each entity that names a model, at the world pose
        // the last propagation left it. A sheared one is drawn sheared, because a world matrix
        // is only ever multiplied, never decomposed.
        const orrery = self.orrery;
        var models = orrery.world.queryOf(.{orrery_mod.Model});
        while (models.next()) |m| {
            const pose = scene.hierarchy.worldTransform(&orrery.world, m.entity) orelse continue;
            self.drawModel(.{ .model = self.modelFor(m.get(orrery_mod.Model).model), .world = pose });
        }
        // M19's cube, a mesh made in code, at an entity's pose like everything else.
        if (orrery.role(.cube)) |cube| {
            if (scene.hierarchy.worldTransform(&orrery.world, cube)) |pose| {
                try self.world.drawMesh(.{ .mesh = self.cube, .material = self.cube_material, .world = pose });
            }
        }

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
        const transforms = if (scene.hierarchy.lastPropagation(&self.orrery.world)) |p| p.entities else 0;
        var buffer: [160]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "{s}  {d}x MSAA  {d} draws  {d} culled  {d} blended  {d} transforms  {d:.2} ms", .{
            app.graphics_backend, self.sample_count, stats.draws, stats.culled, stats.blended, transforms, last_ms,
        }) catch buffer[0..0];
        // At the bottom, and right of the overlay's column while it is open, at its size.
        const bottom: f32 = @as(f32, @floatFromInt(logical.height)) - if (self.panels_open) @as(f32, 20) else 28;
        const left: f32 = if (self.panels_open) panel_width + 24 else 12;
        try self.overlay.drawText(font, line, .{ .position = .init(left, bottom), .scale = if (self.panels_open) 1 else 2 });

        if (self.panels_open) {
            try app.drawUi(&self.ui.list, &self.overlay, .{ .font = font }, .screen, .{});
        }
    }

    fn deinit(self: *Sample, engine: *app.Engine) void {
        if (!self.font_asset.isNone()) engine.assets.release(self.font_asset);
        self.releaseModels();
        self.models.deinit(self.gpa);
        if (self.save_dir) |dir| self.gpa.free(dir);
        self.panels.deinit();
        self.ui.deinit();
        self.orrery.deinit();
        self.gpa.destroy(self.orrery);
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
// The overlay's look, and the keys a run nobody watches presses.

/// The overlay's column, in logical points; the stats line starts right of it while it is open.
const panel_width: f32 = 480;

/// The glyph layout of `foundry:fonts.debug`, before its texture is resident.
fn placeholderFont() render2d.BitmapFont {
    return .{
        .glyphs = .{ .texture = .none, .uv = .{}, .size_px = .{} },
        .cell = .{ .width = 8, .height = 8 },
        .columns = 16,
        .glyph_count = 95,
    };
}

/// The overlay's style: data the sample owns, as `samples/sandbox`'s is (ADR-0024).
fn overlayStyle(font: app.UiFont) ui.Style {
    return .{
        .font = font.metrics(),
        // One glyph cell per point: eight points, sixteen pixels on a Retina display. Twice
        // that fits too few characters of a tree in a column.
        .text_scale = 1,
        .line_height = 14,
        .padding = .init(6, 4),
        .spacing = 3,
        .separator_thickness = 1,
        .text = uiColor(190, 235, 255, 255),
        .text_dim = uiColor(120, 150, 170, 255),
        .surface = uiColor(0, 0, 0, 170),
        .control = uiColor(30, 40, 55, 220),
        .control_hot = uiColor(50, 70, 95, 235),
        .control_active = uiColor(80, 110, 145, 255),
        .accent = uiColor(120, 200, 255, 255),
    };
}

/// sRGB in, linear out, with the renderer's own transfer function.
fn uiColor(r: u8, g: u8, b: u8, a: u8) ui.Color {
    const c = render2d.Color.srgb8(r, g, b, a);
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

/// `FOUNDRY_SANDBOX3D_KEYS`: `key@frame` pairs, comma-separated, for evidence runs. Host
/// bootstrap like the frame limit (ADR-0031), never a game setting.
const Script = struct {
    presses: [max]Press = undefined,
    len: usize = 0,

    const max = 32;
    const Press = struct { key: Key, frame: u64 };
    const Key = enum { f1, f5, f6, f7, f9 };
    const Keys = struct { f1: bool = false, f5: bool = false, f6: bool = false, f7: bool = false, f9: bool = false };

    fn fromEnv(engine: *app.Engine) Script {
        const text = engine.os.envVar("FOUNDRY_SANDBOX3D_KEYS") orelse return .{};
        return parse(text) orelse blk: {
            log.warn("FOUNDRY_SANDBOX3D_KEYS is not a list of key@frame (f1 f5 f6 f7 f9); ignoring it", .{});
            break :blk .{};
        };
    }

    fn parse(text: []const u8) ?Script {
        var out: Script = .{};
        var items = std.mem.tokenizeScalar(u8, text, ',');
        while (items.next()) |item| {
            const at = std.mem.indexOfScalar(u8, item, '@') orelse return null;
            const key = std.meta.stringToEnum(Key, std.mem.trim(u8, item[0..at], " ")) orelse return null;
            const frame = std.fmt.parseInt(u64, std.mem.trim(u8, item[at + 1 ..], " "), 10) catch return null;
            if (out.len == max) return null;
            out.presses[out.len] = .{ .key = key, .frame = frame };
            out.len += 1;
        }
        return out;
    }

    fn pressed(self: *const Script, frame: u64) Keys {
        var keys: Keys = .{};
        for (self.presses[0..self.len]) |p| {
            if (p.frame != frame) continue;
            switch (p.key) {
                inline else => |k| @field(keys, @tagName(k)) = true,
            }
        }
        return keys;
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

test {
    _ = orrery_mod;
}

test "scripted keys are key@frame pairs, and anything else is refused whole" {
    const script = Script.parse("f5@120, f6@150,f9@200,f5@200").?;
    try testing.expectEqual(@as(usize, 4), script.len);
    const at200 = script.pressed(200);
    try testing.expect(at200.f9 and at200.f5 and !at200.f6);
    try testing.expect(script.pressed(150).f6);
    try testing.expect(!script.pressed(151).f6);
    for ([_][]const u8{ "f5", "f2@10", "f5@x", "f5@-1" }) |bad| try testing.expect(Script.parse(bad) == null);
    try testing.expectEqual(@as(usize, 0), Script.parse("").?.len);
}

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
