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
//! - `FOUNDRY_SANDBOX3D_WORKERS=n` sets the engine's worker count, and
//!   `FOUNDRY_SANDBOX3D_BACKGROUND=n` its background pool's;
//! - `FOUNDRY_SANDBOX3D_WALKERS=1|16` selects the M24 cost-run instance count;
//! - `FOUNDRY_SANDBOX3D_ANIMATORS=32` also advances 32 animators of the pacer's machine, both its
//!   layers, with no pose,
//!   in a world of their own, measured as `animation.animators` (`animation-logic.md` §13);
//! - `FOUNDRY_SANDBOX3D_WALK=tour` proves the player and the generated walker, then M37's corner,
//!   then replays; `tilted` does all that and runs both tours again in a world turned 0.7 rad;
//! - `FOUNDRY_SANDBOX3D_PANELS=1` starts with the debug overlay shown;
//! - `FOUNDRY_SANDBOX3D_SAVE_DIR=path` redirects F5/F9 for a disposable evidence run;
//! - `FOUNDRY_SANDBOX3D_KEYS=f5@120,f6@150,...` presses those keys on those frames, as if a
//!   person had, so a run nobody watches still saves, loads and re-parents;
//! - `FOUNDRY_SANDBOX3D_LOAD=background|sync|off` is how M27's gallery loads on its tick
//!   (`background` when unset; `off` waits for G), and the frames around it are measured;
//! - `FOUNDRY_SANDBOX3D_GENERATE=background|inline|off` is how M28's landmark is made on its
//!   tick, and `off` leaves the generated corner out; `FOUNDRY_SANDBOX3D_PAINT=auto` paints the
//!   canvas along a fixed stroke every tick, for a run nobody watches, and
//!   `FOUNDRY_SANDBOX3D_WATER=inline` rewrites the water on the main thread, the baseline;
//! - `FOUNDRY_SANDBOX3D_EFFECTS=on|off` makes M29's effects corner (`effects.zig`) or leaves it
//!   out; P faces it from the patch and B fires its sparks;
//! - **M** slides a crate into the crowd's way (`crowd.zig`, M33), and `m@frame` presses it;
//! - **K** drops a crate on the pacer's square, which it turns at, and lifts it again
//!   (`pacer.zig`, M36), and `k@frame` presses it;
//! - `FOUNDRY_SANDBOX3D_NAV=show` starts with M32's navigation mesh drawn (`nav.zig`), which N
//!   shows and hides, and `off` builds none, measuring the same frames as a baseline.
//!
//! **M22's is a lit room a content mod changes** (`light.md` §10). Lights, ambient and
//! EV100 come from the config; `--shadows=off` disables the shadow map. Player mods live
//! under `foundry-sandbox3d/mods`, selected by comma-separated content IDs in
//! `FOUNDRY_SANDBOX3D_PACKAGES`. The ordinary `testdata/mods/dusk` package changes the
//! complete config and floor/wall materials without code. Headless runs discover user
//! packages only when that explicit selection is present.
//!
//! **M24's is a generated animated walker** (`animation3d.md` §10). Its independent content
//! record supplies the model, patrol waypoints, speed and idle/walk cross-fade. Playback and
//! collision stay sample-owned; poses use tick-derived time and current borrowed assets.
//!
//! **M25 Step 4's is a content-only solid prop** (`public3d.md` §10). Every `sandbox3d:prop`
//! is drawn in content-ID hash order; optional collision assets are copied into static bodies
//! at its position/yaw. The `plinth` test package adds a lit stone object, without code. Solid
//! props keep scale 1 (ADR-0057); decorative props may be scaled. Select `plinth:content`
//! through the existing PACKAGES bootstrap to include its cast/player-blocking tour check.
//!
//! **M25 Step 5's is a consented native orbiter** (`public3d.md` §10). Select its package
//! with PACKAGES and consent separately with `FOUNDRY_SANDBOX3D_NATIVE=orbiter:content`.
//! Its C99 library sees only v6, retains an instance/light and moves matching collision from
//! its fixed-tick hierarchy system. The host submits them after its own draws. F9 refuses
//! rebuilding a world containing native registrations; restart to load without native code.
//! `FOUNDRY_SANDBOX3D_INSTANCES=1024` selects the plinth cost run; NATIVE_TRACE names a
//! developer proof output for the fresh-process driver in `scripts/m25/tour.py`.
//!
//! **M27's is a gallery that loads while the room keeps drawing** (`background.md` §11).
//! Eight framed panels with 2048×2048 textures stand above the crates, drawn only once they
//! are asked for: on a fixed tick, or by **G**, which loads or releases them. By default they
//! are requested and appear once every part has finished; `FOUNDRY_SANDBOX3D_LOAD=sync`
//! loads them on the tick instead, which stalls, as the baseline the background path is
//! measured against.
//!
//! **M28's is geometry made at run time, beside compiled content** (`runtime-geometry.md` §8),
//! in a corner past the crates (`generated.zig`): a seeded patch that is drawn and walked on, a
//! water sheet rewritten every frame, a canvas painted by looking at it, a large landmark
//! generated on the pool, and a crate recoloured by a runtime material binding its compiled
//! texture. **T** puts the player on the patch, **C** clears the canvas and **R** reloads
//! every package.
//!
//! **M37's is collision that moves and knows what it is made of** (`collision-extras.md` §11),
//! in a corner west of the room (`extras.zig`): a lift, a turntable, a crate the player pushes,
//! a door the player stops, a ledge jumped up through from below, and a dense rock that collides
//! as a few boxes at scale 1.5. **L** goes there and **space** jumps; the overlay and the log
//! name the surface underfoot, stone, wood or metal. Its tour (`corner_tour.zig`) runs after
//! M23's, which keeps its pin.

const std = @import("std");

const anim = @import("anim");
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
const walk_mod = @import("walk.zig");
const Tour = @import("tour.zig").Tour;
const Walker = @import("walker.zig").Walker;
const pacer_mod = @import("pacer.zig");
const animators_mod = @import("animators.zig");
const Props = @import("props.zig").Props;
const native_mod = @import("native.zig");
const gallery_mod = @import("gallery.zig");
const Gallery = gallery_mod.Gallery;
const generated = @import("generated.zig");
const effects_mod = @import("effects.zig");
const nav_mod = @import("nav.zig");
const crowd_mod = @import("crowd.zig");
const strafer_mod = @import("strafer.zig");
const extras_mod = @import("extras.zig");
const corner_tour = @import("corner_tour.zig");
const CornerTour = corner_tour.CornerTour;
const yard_mod = @import("yard.zig");
const physics = @import("physics3d");
const YardTour = @import("yard_tour.zig").YardTour;
const Native = native_mod.Native;

const orrery_mod = @import("orrery.zig");
const Orrery = orrery_mod.Orrery;
const LightSettings = @import("light_settings.zig").LightSettings;

const Mat4 = core.math.Mat4;
const Quat = core.math.Quat;
const Vec3 = core.math.Vec3;

const log = core.log.scoped(.sandbox3d);

pub const std_options = app.std_options;

const app_name = "foundry-sandbox3d";
const config_id = "sandbox3d:config.main";
const default_headless_frames: u64 = 120;
/// M34's tour stage (`animation-logic.md` §10), grown in M35 (`animation-states.md` §13): the pacer is
/// saved in mid-stride, the run goes on, and a fresh world loaded from that save has to do the same
/// thing to the bit. Then the same across a save in mid-turn, and an M34 save from before machines
/// has to walk M34's walk.
const PacerProof = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// The figure's hash when the run was `ticks` past the save.
    expected: ?u64 = null,
    /// Whether no package is selected beyond the sample's own, so M34's pin applies.
    base_content: bool = true,

    const save_tick = 100;
    const ticks = 600;
    /// By then it has walked its square, and on past the corner it began at.
    const corners = 4;
    /// Saved by M34's tour code at its `save_tick`, at tag `m34`. With the head still, 600 ticks of it
    /// are M34's replay pin.
    const m34_save = @embedFile("testdata/saves/pacer_m34.fsav");
    const m34_pin: u64 = 0x47f67027ff3a12b0;

    fn deinit(self: *PacerProof, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
    }

    /// Once a tick, after the orrery's step.
    fn note(self: *PacerProof, gpa: std.mem.Allocator, figure: *pacer_mod.Figure, orrery: *Orrery) !void {
        figure.record(&orrery.world);
        if (figure.ticks == save_tick) {
            _ = gpa;
            _ = try orrery.save(&self.bytes);
            figure.hash = pacer_mod.Figure.hash_seed;
        } else if (figure.ticks == save_tick + ticks) {
            self.expected = figure.hash;
        }
    }

    const Run = struct {
        gpa: std.mem.Allocator,
        orrery: *Orrery,
        figure: *pacer_mod.Figure,
        walk: *@import("physics3d").World,
        content: *render3d.Content,
        rigs: *asset.Rigs,
        delta: core.time.Duration,
        ticks: u64 = 0,

        /// A fresh world from `bytes`, its figure stood in `walk`. A save from before machines
        /// becomes one with the pacer's at `refresh`.
        fn load(gpa: std.mem.Allocator, bytes: []const u8, roles: anytype, store: *const data.Store, jobs: core.Jobs, walk: *@import("physics3d").World, content: *render3d.Content, rigs: *asset.Rigs, delta: core.time.Duration) !Run {
            const orrery = try gpa.create(Orrery);
            errdefer gpa.destroy(orrery);
            try orrery.init(gpa, jobs);
            errdefer orrery.deinit();
            orrery.roles = roles;
            _ = orrery.load(bytes, store) orelse return error.PacerTourFailed;
            const figure = try gpa.create(pacer_mod.Figure);
            errdefer gpa.destroy(figure);
            figure.* = .{};
            errdefer figure.deinit(gpa, walk, content, rigs);
            try figure.refresh(gpa, &orrery.world, orrery.role(.pacer), walk, content, rigs);
            return .{ .gpa = gpa, .orrery = orrery, .figure = figure, .walk = walk, .content = content, .rigs = rigs, .delta = delta };
        }

        fn deinit(self: *Run) void {
            self.figure.deinit(self.gpa, self.walk, self.content, self.rigs);
            self.gpa.destroy(self.figure);
            self.orrery.deinit();
            self.gpa.destroy(self.orrery);
        }

        fn stack(self: *Run) *anim.Stack {
            return scene.animation.stack(&self.orrery.world, self.orrery.role(.pacer).?).?;
        }

        fn tick(self: *Run) !void {
            try self.figure.step(self.gpa, &self.orrery.world, self.walk, self.rigs, self.delta.toSecondsF32());
            self.orrery.step(.{ .tick = self.ticks, .delta = self.delta });
            try self.figure.evaluate(&self.orrery.world, self.rigs, null, 0);
            self.figure.record(&self.orrery.world);
            self.ticks += 1;
        }

        fn corners(self: *Run) u32 {
            return pacer_mod.paceIn(&self.orrery.world, self.orrery.role(.pacer).?).?.corners;
        }
    };

    fn prove(self: *PacerProof, gpa: std.mem.Allocator, orrery: *const Orrery, store: *const data.Store, jobs: core.Jobs, walk: *@import("physics3d").World, content: *render3d.Content, rigs: *asset.Rigs, delta: core.time.Duration) !void {
        const expected = self.expected orelse return error.PacerTourFailed;
        var live = try Run.load(gpa, self.bytes.items, orrery.roles, store, jobs, walk, content, rigs, delta);
        defer live.deinit();
        for (0..ticks) |_| try live.tick();
        if (live.figure.hash != expected or live.corners() < corners) {
            log.warn("tour: FAIL pacer ({x:0>16} after the load, {x:0>16} without it, {d} corners)", .{ live.figure.hash, expected, live.corners() });
            return error.PacerTourFailed;
        }
        log.info("tour: pacer pass ({d} ticks across a save and a load, {d} corners, {d} footfalls, {d} bytes, replay {x:0>16})", .{ ticks, live.corners(), live.figure.footfalls, self.bytes.items.len, live.figure.hash });

        // On into the next corner, and saved halfway through its turn.
        const turn = anim.clipName("turn");
        var guard: u32 = 0;
        while (live.stack().layers[0].state != turn or live.stack().layers[0].state_ticks != 24) : (guard += 1) {
            if (guard > 2000) return error.PacerTourFailed;
            try live.tick();
        }
        var turning: std.ArrayList(u8) = .empty;
        defer turning.deinit(gpa);
        _ = try live.orrery.save(&turning);
        live.figure.hash = pacer_mod.Figure.hash_seed;
        const at = live.corners();
        for (0..ticks) |_| try live.tick();
        var turned = try Run.load(gpa, turning.items, orrery.roles, store, jobs, walk, content, rigs, delta);
        defer turned.deinit();
        for (0..ticks) |_| try turned.tick();
        if (turned.figure.hash != live.figure.hash or turned.corners() <= at) {
            log.warn("tour: FAIL pacer mid-turn ({x:0>16} after the load, {x:0>16} without it)", .{ turned.figure.hash, live.figure.hash });
            return error.PacerTourFailed;
        }
        log.info("tour: pacer mid-turn pass ({d} ticks across the turn's end and its fade, {d} bytes, replay {x:0>16})", .{ ticks, turning.items.len, turned.figure.hash });

        // M34's save: no machine in it, and the head held still so the pose is the body's alone.
        var old = try Run.load(gpa, m34_save, orrery.roles, store, jobs, walk, content, rigs, delta);
        defer old.deinit();
        try anim.machine.set(old.stack(), old.figure.machineOf(rigs).?.*, anim.clipName("look"), 0);
        for (0..ticks) |_| try old.tick();
        if (!self.base_content) {
            // A package may restate the set or the machine, and then M34's walk is not this one.
            log.info("tour: pacer M34 save carries on ({d} ticks, {d} corners, replay {x:0>16}); M34's pin is the base content's, and a package is selected", .{ ticks, old.corners(), old.figure.hash });
            return;
        }
        if (old.figure.hash != m34_pin) {
            log.warn("tour: FAIL pacer from M34's save ({x:0>16}, M34's pin {x:0>16})", .{ old.figure.hash, m34_pin });
            return error.PacerTourFailed;
        }
        log.info("tour: pacer M34 save pass ({d} ticks from a version 1 save, {d} bytes, M34's replay {x:0>16})", .{ ticks, m34_save.len, old.figure.hash });
    }
};

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
            err.interface.writeAll("usage: sandbox3d [--msaa=1|4] [--cull=on|off] [--shadows=off] [--shadow-proof]\n") catch {};
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
    shadow_proof: bool = false,
    shadows: bool = true,

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
        } else if (std.mem.eql(u8, arg, "--shadow-proof")) {
            self.shadow_proof = true;
        } else if (std.mem.eql(u8, arg, "--shadows=off")) {
            self.shadows = false;
        } else return false;
        return true;
    }
};

fn run(gpa: std.mem.Allocator, env: []const platform.os.EnvVar, options: Options) !void {
    const headless = platform.backend == .null;

    // Discovery before the engine, as every host does it (`public-abi.md` §13): the
    // installation and player's mods are distinct host grants. Headless runs only
    // discover ambient user packages when explicitly requested, like the 2D samples.
    var os = try platform.os.Os.init(gpa, .{ .env = env, .app_name = app_name });
    defer os.deinit();
    const content_dir = try app.contentDirOf(gpa, os, null);
    defer gpa.free(content_dir);

    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    const selected_text = os.envVar("FOUNDRY_SANDBOX3D_PACKAGES");
    const user_dir = if (!headless or selected_text != null) try app.mods.userRoot(gpa, os) else null;
    defer if (user_dir) |dir| gpa.free(dir);
    const roots = [_]app.mods.Root{
        .{ .dir = content_dir, .origin = .installed },
        .{ .dir = user_dir orelse "", .origin = .user },
    };
    var mods = try app.ModSet.init(gpa, os, roots[0..if (user_dir != null) @as(usize, 2) else 1], .{
        .required = &.{ try data.contentId("foundry:core"), try data.contentId("sandbox3d:content") },
    }, &diags);
    defer mods.deinit();
    var selected: std.ArrayList(core.ContentId) = .empty;
    defer selected.deinit(gpa);
    if (selected_text) |text| {
        var names = std.mem.splitScalar(u8, text, ',');
        while (names.next()) |raw| {
            const name = std.mem.trim(u8, raw, " ");
            if (name.len == 0) continue;
            const id = data.contentId(name) catch {
                log.warn("FOUNDRY_SANDBOX3D_PACKAGES: '{s}' is not a content id", .{name});
                continue;
            };
            try selected.append(gpa, id);
            log.info("enabling '{s}'", .{name});
        }
    }
    _ = mods.start(selected.items, &diags) catch |err| {
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
        // M27 Step 9's sweep: the background pool's threads, measured at 1, 2 and 4.
        .background_workers = countFrom(env, "FOUNDRY_SANDBOX3D_BACKGROUND"),
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
    // M34's pin is the base content's walk; a selected package may restate it.
    sample.pacer_proof.base_content = selected.items.len == 0;
    defer sample.deinit(engine);
    if (frameLimit(engine, headless) == null and os.envVar("FOUNDRY_SANDBOX3D_KEYS") == null and os.envVar("FOUNDRY_SANDBOX3D_WALK") == null) sample.rememberPanels(engine);
    try sample.load(engine);
    const native = try gpa.create(Native);
    defer gpa.destroy(native);
    try native.init(engine, &sample.orrery.world, &sample.content.?, &sample.walk.world);
    defer native.deinit(); // before Sample.deinit and every lent subsystem
    sample.native = native;
    const consent = native_mod.Consent.parse(os.envVar("FOUNDRY_SANDBOX3D_NATIVE")) catch |err| blk: {
        log.warn("FOUNDRY_SANDBOX3D_NATIVE refused ({t}); no native consent granted", .{err});
        break :blk native_mod.Consent{};
    };
    try native.load(mods.loaded().?.order, consent, &diags);
    if (os.envVar("FOUNDRY_SANDBOX3D_INSTANCES")) |count| {
        if (!std.mem.eql(u8, count, "1024")) return error.InvalidInstanceCount;
        try native.fillStress();
    }
    // Null normally advances 1 ms/frame. An explicit tour advances fixed simulation time,
    // not thousands of empty rendered frames, and never changes the engine's timestep.
    if (headless) if (sample.tour != null) engine.platform.setClockStep(engine.step_delta);

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
    var pace_next: u64 = 0;
    while (!engine.shouldQuit()) {
        // Time this frame spent asleep on purpose, which the gallery's window leaves out.
        var paced_ns: i64 = 0;
        const frame_started = if (!headless) engine.os.monotonicNanos() else 0;
        engine.beginFrame();
        if (sample.content_generation != engine.contentGeneration()) sample.refresh(engine);
        // Beside the engine's asset pump, before simulation: what the pool filled finishes.
        if (sample.corner) |corner| corner.pump(engine, @as(f32, @floatFromInt(engine.stepper.tick)) * engine.step_delta.toSecondsF32());
        {
            const scope = engine.beginScope("navigation.pump");
            defer scope.end();
            sample.navigation.pump(engine.frame_index, engine.os.monotonicNanos());
            // Before this frame's ticks: a mesh reaches the crowd at a frame boundary, as an
            // input does (ADR-0061's decision 4).
            if (sample.navigation.takeAdoption()) |mesh| sample.crowd.adopt(mesh);
            sample.navigation.service(engine.tasks(), &engine.store, &engine.assets, &sample.props, sample.crateObstacle(), engine.frame_index, engine.os.monotonicNanos());
        }

        // Drained so the window keeps answering; the engine acts on a close itself. Text is
        // kept for the overlay's filter box.
        sample.typed_len = 0;
        while (engine.nextEvent()) |ev| sample.noteEvent(ev);
        // **The overlay first, before a key is read**, so a key the filter box took is not
        // also a command (`ui.md` step 6).
        try sample.describeUi(engine);
        if (engine.input.wasPressed(.escape)) engine.requestQuit();
        sample.keys(engine, script.pressed(engine.frame_index));
        // R reloads here, and a rig must not reach a tick holding what that replaced.
        if (sample.content_generation != engine.contentGeneration()) sample.refresh(engine);
        while (engine.nextStep()) |step| try sample.step(engine, step);

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

        // A skipped frame presented nothing, and would otherwise spin a core. The null
        // backend has no swapchain to wait on either.
        if (skipped) {
            engine.os.sleep(engine.step_delta);
            paced_ns = engine.step_delta.ns;
        }
        if (!headless and !skipped) {
            // The display may be 120 Hz. Bound this demonstrator to its documented
            // 60 Hz budget, without changing simulation time or the RHI's FIFO policy.
            const budget: u64 = @intCast(engine.step_delta.ns);
            pace_next = if (pace_next == 0) frame_started + budget else pace_next + budget;
            const now = engine.os.monotonicNanos();
            if (now < pace_next) {
                engine.os.sleep(.fromNanos(@intCast(pace_next - now)));
                paced_ns = @intCast(engine.os.monotonicNanos() - now); // Measurement only.
            } else if (now - pace_next > 250 * core.time.ns_per_ms) {
                // Resize, minimise and restore must not provoke a catch-up burst.
                pace_next = now;
            }
        }
        if (skipped) pace_next = 0;
        engine.endFrame();
        if (engine.profiler()) |recorder| {
            sample.gallery.window.add(recorder, paced_ns);
            if (sample.corner) |corner| corner.landmark.window.add(recorder, paced_ns);
            sample.navigation.window.add(recorder, paced_ns);
        }
        if (sample.tour) |*tour| if (tour.done() and sample.walkers[0].tick >= Walker.proof_ticks and
            (if (sample.corner_tour) |*ct| ct.done() or tour.failed != null else true) and
            (if (sample.yard_tour) |*yt| yt.done() or (sample.corner_tour != null and sample.corner_tour.?.failed != null) or tour.failed != null else true)) break;

        if (frame_limit) |limit| {
            if (engine.frame_index >= limit) break;
        }
    }

    if (sample.tour) |*tour| {
        if (!tour.done() or tour.failed != null) return error.TourFailed;
        if (native.orbiter_owner != null and (!native.blocked or native.ticks != Native.proof_ticks)) return error.OrbiterTourFailed;
        var replay = walk_mod.Walk.init(gpa);
        defer replay.deinit(&engine.assets);
        replay.refresh(&engine.store, &engine.assets, engine.step_delta.toSecondsF32());
        var replay_props: Props = .{};
        defer replay_props.deinit(gpa, &replay.world, &sample.content.?, &engine.assets);
        try replay_props.refresh(gpa, &engine.store, &replay.world, &sample.content.?, &engine.assets);
        var second: Tour = .{ .emit = false };
        // The replay runs unpaced, back to back, so its moves are timed at a busy CPU's
        // clock; the frame loop's are timed between paced frames (collision3d.md Step 5).
        var replay_times: [Tour.max_ticks]i64 = undefined;
        var replay_count: usize = 0;
        while (!second.done()) {
            const started = engine.os.monotonicNanos(); // Measurement only.
            try second.advance(&replay, engine.step_delta.toSecondsF32());
            replay_times[replay_count] = @intCast(engine.os.monotonicNanos() - started);
            replay_count += 1;
        }
        var replay_scratch: [Tour.max_ticks]i64 = undefined;
        const unpaced = core.profile.summarise(replay_times[0..replay_count], &replay_scratch);
        if (!tour.replayMatches(&second)) {
            log.warn("tour: FAIL replay", .{});
            return error.TourFailed;
        }
        log.info("tour: replay pass ({d} ticks, {x:0>16}); unpaced moves median {d:.4}ms p95 {d:.4}ms", .{ tour.len, tour.hash, ms(unpaced.median_ns), ms(unpaced.p95_ns) });
        log.info("tour: pass", .{});
        const walker = &sample.walkers[0];
        if (!walker.proofPassed()) return error.WalkerTourFailed;
        var replay_walker: Walker = .{};
        defer replay_walker.deinit(gpa, &replay.world, &sample.content.?, &sample.rigs);
        try replay_walker.refresh(gpa, &engine.store, &replay.world, &sample.content.?, &sample.rigs);
        while (replay_walker.tick < Walker.proof_ticks) {
            try replay_walker.move(gpa, &replay.world, &sample.rigs, engine.step_delta.toSecondsF32());
            try replay_walker.evaluate(&sample.rigs);
            replay_walker.record();
        }
        if (!replay_walker.proofPassed() or replay_walker.hash != walker.hash) return error.WalkerReplayFailed;
        log.info("tour: walker pass ({d} ticks, {d} waypoints, idle/walk/cross-fade, replay {x:0>16}); player hash {x:0>16}", .{ walker.tick, walker.reached, walker.hash, tour.hash });
        try sample.pacer_proof.prove(gpa, sample.orrery, &engine.store, engine.jobs(), &replay.world, &sample.content.?, &sample.rigs, engine.step_delta);
        try proveCorner(gpa, engine, &sample, &replay, &second);
        try proveYard(gpa, engine, &sample, &replay);
    }

    sample.gallery.window.report();
    if (sample.corner) |corner| corner.report();
    if (sample.effects) |effects| effects.report();
    sample.navigation.window.report();
    report(gpa, engine, &sample, skipped_frames);
    if (engine.os.envVar("FOUNDRY_SANDBOX3D_NATIVE_TRACE")) |path| {
        if (native.ticks != Native.proof_ticks or !native.blocked) return error.IncompleteNativeTrace;
        try engine.os.writeFile(path, std.mem.sliceAsBytes(&native.trace));
    }
}

/// M37's stages (`collision-extras.md` §11): the frame loop's pass, replayed byte for byte in a
/// fresh walk and corner after M23's replay, and with `tilted`, both tours again in a world
/// turned by `corner_tour.tilt`, matched to the frame loop's every tick within 5 mm.
fn proveCorner(gpa: std.mem.Allocator, engine: *app.Engine, sample: *Sample, replay: *walk_mod.Walk, upright: *const Tour) !void {
    const ct = &(sample.corner_tour orelse return);
    if (sample.extras.settings == null) {
        log.warn("tour: FAIL the M37 corner is not there", .{});
        return error.CornerTourFailed;
    }
    if (!ct.done() or ct.failed != null) return error.CornerTourFailed;
    const dt = engine.step_delta.toSecondsF32();
    var replay_extras: extras_mod.Extras = .{};
    defer replay_extras.deinit(gpa, &replay.world, &engine.assets, null);
    replay_extras.refresh(gpa, &engine.store, &replay.world, &engine.assets, null);
    const second = try gpa.create(CornerTour);
    defer gpa.destroy(second);
    second.* = .{ .emit = false };
    while (!second.done()) try second.advance(replay, &replay_extras, dt);
    if (second.failed != null or second.hash != ct.hash) {
        log.warn("tour: FAIL corner replay ({x:0>16} against {x:0>16})", .{ second.hash, ct.hash });
        return error.CornerTourFailed;
    }
    log.info("tour: corner replay pass ({d} ticks, {x:0>16})", .{ ct.len, ct.hash });
    if (!sample.tilted) return;
    var tilted = walk_mod.Walk.init(gpa);
    defer tilted.deinit(&engine.assets);
    tilted.frame = corner_tour.tilt();
    tilted.refresh(&engine.store, &engine.assets, dt);
    var tilted_extras: extras_mod.Extras = .{ .frame = tilted.frame };
    defer tilted_extras.deinit(gpa, &tilted.world, &engine.assets, null);
    tilted_extras.refresh(gpa, &engine.store, &tilted.world, &engine.assets, null);
    const five = try gpa.create(Tour);
    defer gpa.destroy(five);
    five.* = .{ .emit = false };
    while (!five.done()) try five.advance(&tilted, dt);
    const six = try gpa.create(CornerTour);
    defer gpa.destroy(six);
    six.* = .{ .emit = false };
    while (!six.done()) try six.advance(&tilted, &tilted_extras, dt);
    const a = corner_tour.compare(upright.trace[0..upright.len], five.trace[0..five.len], 5e-3);
    const b = corner_tour.compare(ct.trace[0..ct.len], six.trace[0..six.len], 5e-3);
    if (five.failed != null or six.failed != null or !a.matches or !b.matches) {
        log.warn("tour: FAIL tilted ({s}, {s}; worst {d:.5} m and {d:.5} m)", .{ five.failed orelse "passed", six.failed orelse "passed", a.worst, b.worst });
        return error.TiltedTourFailed;
    }
    log.info("tour: tilted pass ({d} and {d} ticks turned 0.7 rad, every stage passed; worst {d:.5} m and {d:.5} m from upright)", .{ five.len, six.len, a.worst, b.worst });
}

/// M38's stage (`collision-scale.md` §11): the frame loop's pass, replayed byte for byte in a
/// fresh yard after M37's replay, and with `tilted`, again in a world turned by
/// `corner_tour.tilt`, matched to the frame loop's within 15 mm a tick and 2 mm at its end.
fn proveYard(gpa: std.mem.Allocator, engine: *app.Engine, sample: *Sample, replay: *walk_mod.Walk) !void {
    const yt = &(sample.yard_tour orelse return);
    if (sample.yard.settings == null) {
        log.warn("tour: FAIL the M38 yard is not there", .{});
        return error.YardTourFailed;
    }
    if (!yt.done() or yt.failed != null) return error.YardTourFailed;
    const dt = engine.step_delta.toSecondsF32();
    var replay_yard: yard_mod.Yard = .{};
    defer replay_yard.deinit(gpa, &replay.world, &engine.assets, null);
    replay_yard.refresh(gpa, &engine.store, &replay.world, &engine.assets, null, null);
    const second = try gpa.create(YardTour);
    defer gpa.destroy(second);
    second.* = .{ .emit = false };
    while (!second.done()) try second.advance(replay, &replay_yard, dt);
    if (second.failed != null or second.hash != yt.hash) {
        log.warn("tour: FAIL yard replay ({x:0>16} against {x:0>16})", .{ second.hash, yt.hash });
        return error.YardTourFailed;
    }
    log.info("tour: yard replay pass ({d} ticks, {x:0>16})", .{ yt.len, yt.hash });
    if (!sample.tilted) return;
    var tilted = walk_mod.Walk.init(gpa);
    defer tilted.deinit(&engine.assets);
    tilted.frame = corner_tour.tilt();
    tilted.refresh(&engine.store, &engine.assets, dt);
    var tilted_yard: yard_mod.Yard = .{ .frame = tilted.frame };
    defer tilted_yard.deinit(gpa, &tilted.world, &engine.assets, null);
    tilted_yard.refresh(gpa, &engine.store, &tilted.world, &engine.assets, null, null);
    const turned = try gpa.create(YardTour);
    defer gpa.destroy(turned);
    turned.* = .{ .emit = false };
    while (!turned.done()) try turned.advance(&tilted, &tilted_yard, dt);
    const match = corner_tour.compare(yt.trace[0..yt.len], turned.trace[0..turned.len], 15e-3);
    const end = if (yt.len == turned.len and yt.len > 0) yt.trace[yt.len - 1].sub(turned.trace[yt.len - 1]).length() else std.math.inf(f32);
    if (turned.failed != null or !match.matches or end > 2e-3) {
        log.warn("tour: FAIL tilted yard ({s}; worst {d:.5} m, {d:.5} m at the end)", .{ turned.failed orelse "passed", match.worst, end });
        return error.TiltedTourFailed;
    }
    log.info("tour: tilted yard pass ({d} ticks turned 0.7 rad; worst {d:.5} m, {d:.5} m at the end)", .{ turned.len, match.worst, end });
}

/// What a run has to say for itself: how many frames, the pacing of the last ones and what
/// each stage of a frame cost.
fn report(gpa: std.mem.Allocator, engine: *app.Engine, sample: *Sample, skipped_frames: u64) void {
    var move_scratch: [Tour.max_ticks + CornerTour.max_ticks]i64 = undefined;
    const moves = core.profile.summarise(sample.move_times[0..sample.move_count], &move_scratch);
    log.info("character: {d} moves, median {d:.4}ms p95 {d:.4}ms", .{ moves.count, ms(moves.median_ns), ms(moves.p95_ns) });
    if (sample.sweep_count > 0) {
        var sweep_scratch: [CornerTour.max_ticks]i64 = undefined;
        const sweeps = core.profile.summarise(sample.sweep_times[0..sample.sweep_count], &sweep_scratch);
        log.info("door: {d} sweeps, median {d:.4}ms p95 {d:.4}ms", .{ sweeps.count, ms(sweeps.median_ns), ms(sweeps.p95_ns) });
    }
    if (sample.yard_move_count > 0) {
        var yard_scratch: [YardTour.max_ticks]i64 = undefined;
        const yard_moves = core.profile.summarise(sample.yard_move_times[0..sample.yard_move_count], &yard_scratch);
        const movers = core.profile.summarise(sample.mover_times[0..sample.mover_count], &yard_scratch);
        const held = sample.walk.world.report();
        const bodies = held.bodies_static + held.bodies_kinematic;
        log.info("yard: {d} moves among {d} bodies, median {d:.4}ms p95 {d:.4}ms; movers' moveBody, {d} together, median {d:.4}ms p95 {d:.4}ms", .{ yard_moves.count, bodies, ms(yard_moves.median_ns), ms(yard_moves.p95_ns), sample.yard.movers.items.len, ms(movers.median_ns), ms(movers.p95_ns) });
    }
    const stats = sample.world.frameStats();
    log.info("skinning: {d} draws, {d} vertices, {d} budget drops", .{ stats.skinned_draws, stats.skinned_vertices, stats.skin_budget_dropped });
    log.info("lighting: {d} lights, {d} shadow draws, {d} shadow culled", .{ stats.lights, stats.shadow_draws, stats.shadow_culled });
    log.info("stopped after {d} frames ({d} skipped), {d} ticks; last frame {d} draws, {d} culled, {d} blended, {d} triangles", .{
        engine.frame_index, skipped_frames, engine.stepper.tick, stats.draws, stats.culled, stats.blended, stats.triangles,
    });

    const recorder = engine.profiler() orelse return;
    for ([_][]const u8{ "animation", "render.skin", "abi.instances", "animation.animators", "animation.strafer" }) |name| {
        var values: [240]i64 = undefined;
        var work: [240]i64 = undefined;
        var count: usize = 0;
        var frames = recorder.frames();
        while (frames.next()) |frame| {
            if (count == values.len) break;
            var total: i64 = 0;
            var found = false;
            for (frame.spans) |span| if (std.mem.eql(u8, recorder.nameOf(span.name), name)) {
                total += span.durationNs();
                found = true;
            };
            if (found) {
                values[count] = total;
                count += 1;
            }
        }
        // The cost run's line, only when it ran.
        if (count == 0 and (std.mem.eql(u8, name, "animation.animators") or std.mem.eql(u8, name, "animation.strafer"))) continue;
        const measured = core.profile.summarise(values[0..count], &work);
        const instances = if (sample.native) |native| native.instances.instances.count() else 0;
        log.info("{s}: {d} objects, {d} frames, median {d:.4}ms p95 {d:.4}ms", .{ name, if (std.mem.eql(u8, name, "abi.instances")) instances else if (std.mem.eql(u8, name, "animation.animators")) animators_mod.count else if (std.mem.eql(u8, name, "animation.strafer")) @as(usize, 1) else sample.walkers.len, measured.count, ms(measured.median_ns), ms(measured.p95_ns) });
    }
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
    return if (headless) (if (engine.os.envVar("FOUNDRY_SANDBOX3D_WALK") != null) Walker.proof_ticks + 60 else default_headless_frames) else null;
}

fn workersFrom(env: []const platform.os.EnvVar) ?u16 {
    return countFrom(env, "FOUNDRY_SANDBOX3D_WORKERS");
}

fn countFrom(env: []const platform.os.EnvVar, comptime name: []const u8) ?u16 {
    for (env) |v| {
        if (!std.mem.eql(u8, v.name, name)) continue;
        return std.fmt.parseInt(u16, v.value, 10) catch {
            log.warn(name ++ "='{s}' is not a thread count; the engine chooses", .{v.value});
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
    lighting: LightSettings = .{},

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
            .lighting = LightSettings.read(record.fields) catch blk: {
                log.warn("invalid exposure, ambient or lights in '{s}'; lighting disabled", .{config_id});
                break :blk .{};
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

/// The overlay's remembered layout, in the sample's user data directory.
const panels_file = "overlay-panels.txt";

const Sample = struct {
    gpa: std.mem.Allocator,
    sample_count: u32,
    world: render3d.Renderer,
    overlay: render2d.Renderer,
    walk: walk_mod.Walk,
    props: Props = .{},
    props_proved: bool = false,
    /// M37's corner of moving pieces, its tour after M23's, and whether the tilted tour follows.
    extras: extras_mod.Extras = .{},
    corner_tour: ?CornerTour = null,
    tilted: bool = false,
    /// The surface last said to be under the player, so the log names a change once.
    underfoot: core.ContentId = .none,
    sweep_times: [CornerTour.max_ticks]i64 = undefined,
    sweep_count: usize = 0,
    /// M38's yard of stones, movers and a boulder on a baked hillside, and its stage after M37's.
    yard: yard_mod.Yard = .{},
    yard_tour: ?YardTour = null,
    /// Whether the hillside's `addMesh` has been said, which it is once, at the first load.
    yard_said: bool = false,
    /// The player's moves in the yard's stage and the movers' together, a tick each.
    yard_move_times: [YardTour.max_ticks]i64 = undefined,
    yard_move_count: usize = 0,
    mover_times: [YardTour.max_ticks]i64 = undefined,
    mover_count: usize = 0,
    /// What the walk world holds and was asked, for the overlay's physics panel, and the counters
    /// as they stood at its last frame, so it shows a frame's work without taking them.
    physics_report: physics.Report = .{},
    physics_last: physics.Report = .{},
    native: ?*Native = null,
    walkers: []Walker,
    rigs: asset.Rigs,
    pacer: pacer_mod.Figure = .{},
    /// The crate K drops on the pacer's square (`animation-ik.md` §9).
    pacer_block: pacer_mod.Block = .{},
    /// M36's strafer, circling on `walk8` (`animation-ik.md` §12).
    strafer: strafer_mod.Strafer = .{},
    /// The 32-animator cost run, when asked for.
    animators: ?animators_mod.Animators = null,
    /// The tour's save, and what the run went on to do after it.
    pacer_proof: PacerProof = .{},
    course: render3d.ModelHandle = .none,
    /// M27's gallery: held only once asked for, on its tick or by G.
    gallery: Gallery = .{},
    /// M28's generated corner, made at `load` unless `FOUNDRY_SANDBOX3D_GENERATE=off`. On the
    /// heap, because its CPU canvas and water are large.
    corner: ?*generated.Corner = null,
    /// M29's effects corner, made at `load` unless `FOUNDRY_SANDBOX3D_EFFECTS=off`.
    effects: ?*effects_mod.Effects = null,
    /// M32's navigation mesh, built on the pool at each content refresh; N draws it.
    navigation: nav_mod.Navigation,
    /// M33's crowd on that mesh, and the crate M slides into its way.
    crowd: crowd_mod.CrowdDemo,
    nav_report: @import("nav").Report = .{},
    intent: walk_mod.Intent = .{},
    tour: ?Tour = null,
    move_times: [Tour.max_ticks + CornerTour.max_ticks]i64 = undefined,
    move_count: usize = 0,
    /// Created in `load`, once `world` is at its final address, because it borrows it.
    content: ?render3d.Content = null,

    cube: render3d.MeshHandle,
    cube_material: render3d.MaterialHandle,
    /// Step 5's opt-in caster/receiver proof; the ordinary room stays unlit until Step 7.
    shadow_ground: render3d.MeshHandle = .none,
    shadow_material: render3d.MaterialHandle = .none,

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
    /// Whether the overlay's open panels are kept between runs: a person's session only,
    /// never one bounded, keyed or touring, which must write nothing of a player's.
    remembers_panels: bool = false,
    /// The poses F5 last saved, so F9 can say whether it brought back the same ones.
    saved_hash: ?u64 = null,
    typed: [8]platform.event.TextInput = undefined,
    typed_len: usize = 0,

    /// What the camera looks at: the table's top, where the orrery stands.
    const focus: Vec3 = .init(0, 0.8, 0);

    fn init(gpa: std.mem.Allocator, engine: *app.Engine, options: Options) !Sample {
        var world = try render3d.Renderer.init(gpa, engine.gpu, .{ .jobs = engine.jobs(), .sample_count = options.sample_count, .cull = options.cull, .shadow_size = if (options.shadows) 2048 else 0 });
        errdefer world.deinit();
        var overlay = try render2d.Renderer.init(gpa, engine.gpu, .{ .jobs = engine.jobs() });
        errdefer overlay.deinit();

        const cube_material = try world.createMaterial(.{ .shading = render3d.lit_id, .roughness = 0.65 }, "sandbox3d cube");
        errdefer world.destroyMaterial(cube_material);
        const cube = try createBox(&world, .init(0.6, 0.6, 0.6), cube_faces, "sandbox3d cube");
        errdefer world.destroyMesh(cube);
        const shadow_ground = if (options.shadow_proof) try createShadowGround(&world) else render3d.MeshHandle.none;
        const shadow_material = if (options.shadow_proof) try world.createMaterial(.{ .shading = render3d.lit_id, .base_color = .{ 0.6, 0.6, 0.6, 1 }, .roughness = 0.8 }, "shadow proof receiver") else render3d.MaterialHandle.none;

        const orrery = try gpa.create(Orrery);
        errdefer gpa.destroy(orrery);
        try orrery.init(gpa, engine.jobs());
        errdefer orrery.deinit();
        // Wider than the default column, because the tree's rows are indented.
        const panels = try debug.Overlay.init(gpa, .{ .panel_width = panel_width });
        errdefer panels.deinit();
        const walker_count: usize = if (engine.os.envVar("FOUNDRY_SANDBOX3D_WALKERS")) |text| blk: {
            if (std.mem.eql(u8, text, "16")) break :blk 16;
            if (!std.mem.eql(u8, text, "1")) log.warn("WALKERS must be 1 or 16; using one", .{});
            break :blk 1;
        } else 1;
        const walkers = try gpa.alloc(Walker, walker_count);
        @memset(walkers, .{});
        const animators: ?animators_mod.Animators = if (engine.os.envVar("FOUNDRY_SANDBOX3D_ANIMATORS")) |text| blk: {
            if (std.mem.eql(u8, text, "32")) break :blk .{};
            log.warn("ANIMATORS must be 32; running none", .{});
            break :blk null;
        } else null;

        return .{
            .gpa = gpa,
            .sample_count = options.sample_count,
            .world = world,
            .overlay = overlay,
            .walk = walk_mod.Walk.init(gpa),
            .navigation = nav_mod.Navigation.init(gpa),
            .crowd = crowd_mod.CrowdDemo.init(gpa),
            .walkers = walkers,
            .animators = animators,
            .rigs = asset.Rigs.init(gpa, &engine.assets),
            .cube = cube,
            .cube_material = cube_material,
            .shadow_ground = shadow_ground,
            .shadow_material = shadow_material,
            .orrery = orrery,
            .ui = .init(gpa, overlayStyle(.{ .font = placeholderFont() })),
            .panels = panels,
        };
    }

    /// The texture loader and `Content` both borrow the renderers, so this waits until the
    /// sample has reached its final address.
    fn load(self: *Sample, engine: *app.Engine) !void {
        try engine.assets.registerLoader(self.gpa, render2d.textureLoader(&self.overlay));
        try engine.assets.registerLoader(self.gpa, asset.collisionMeshLoader());
        try engine.assets.registerLoader(self.gpa, asset.collisionHullLoader());
        if (engine.os.envVar("FOUNDRY_SANDBOX3D_WALK")) |mode| {
            const tilted = std.mem.eql(u8, mode, "tilted");
            if (std.mem.eql(u8, mode, "tour") or tilted) {
                self.tour = .{};
                self.corner_tour = .{};
                self.yard_tour = .{};
                self.tilted = tilted;
            } else log.warn("unknown walk mode '{s}'; using keys", .{mode});
        }
        self.content = render3d.Content.init(self.gpa, &self.world, &engine.assets, .default);
        self.gallery.mode = gallery_mod.Mode.parse(engine.os.envVar("FOUNDRY_SANDBOX3D_LOAD"));
        // Before the first refresh, which makes the first request.
        if (engine.os.envVar("FOUNDRY_SANDBOX3D_NAV")) |value| {
            if (std.mem.eql(u8, value, "show")) {
                self.navigation.shown = true;
            } else if (std.mem.eql(u8, value, "off")) {
                self.navigation.off = true;
            } else log.warn("FOUNDRY_SANDBOX3D_NAV='{s}' is neither show nor off; the mesh starts hidden", .{value});
        }
        self.refresh(engine);
        // After the walk world exists and before the first tick: the patch is simulation.
        const generate = generated.Mode.parse(engine.os.envVar("FOUNDRY_SANDBOX3D_GENERATE"));
        if (generate != .off) {
            const corner = try self.gpa.create(generated.Corner);
            errdefer self.gpa.destroy(corner);
            try corner.init(engine, generate, &self.world, &self.content.?, &self.walk.world);
            self.corner = corner;
        }
        if (effects_mod.Mode.parse(engine.os.envVar("FOUNDRY_SANDBOX3D_EFFECTS")) == .on) {
            const effects = try self.gpa.create(effects_mod.Effects);
            errdefer self.gpa.destroy(effects);
            try effects.init(self.gpa, &self.world, &self.content.?);
            self.effects = effects;
        }

        self.orrery.populate(&engine.store);
        self.refreshPacer(engine);
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
        log.info("keys: WASD walk, arrows/right mouse look, f4 capture the pointer to look, f3 walk/orbit, f1 overlay, f5 save, f9 load, f6 move the orbiting crate, f7 try the sheared one, g load or release the gallery, t go to the generated corner, c clear its canvas, p face the effects, b fire the sparks, n show the navigation mesh, m slide the crate, l go to the M37 corner, y go to the M38 yard, space jump, r reload content, escape quit", .{});
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
        const previous_course = if (self.walk.settings) |s| s.course else core.ContentId.none;
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
            // A rig borrows what a reload may have replaced, so this comes before any tick.
            self.rigs.contentChanged() catch |err|
                log.warn("the rigs could not follow a content change ({t})", .{err});
            if (self.corner) |corner| corner.noteReload(&self.world);
            if (self.effects) |effects| effects.contentChanged();
            if (self.content) |*content| self.navigation.contentChanged(content);
            self.releaseModels();
        }
        self.room = self.follow(self.room, before.room, self.settings.room, first);
        self.crate = self.follow(self.crate, before.crate, self.settings.crate, first);
        self.crate_override = self.followMaterial(before.crate_override, first);
        self.walk.refresh(&engine.store, &engine.assets, engine.step_delta.toSecondsF32());
        self.props_proved = false;
        if (self.content) |*content| self.props.refresh(self.gpa, &engine.store, &self.walk.world, content, &engine.assets) catch |err|
            log.warn("prop set omitted ({t})", .{err});
        self.course = self.follow(self.course, previous_course, if (self.walk.settings) |s| s.course else .none, first);
        self.crowd.refresh(&engine.store, if (self.content) |*content| content else null);
        self.crowd.bindFigure(&self.rigs, if (self.content) |*content| content else null);
        // The climber's feet find the course in the walk world (`animation-ik.md` §12).
        self.crowd.ground = &self.walk.world;
        // After the props, whose collision it is built from too.
        const asked = engine.os.monotonicNanos(); // Measurement only.
        // The crowd was rebuilt, so it must be given the mesh again even if none arrives new.
        if (self.navigation.mesh()) |mesh| self.crowd.adopt(mesh);
        self.navigation.request(engine.tasks(), &engine.store, &engine.assets, &self.props, self.crateObstacle(), engine.frame_index, asked);
        self.navigation.noteRequestCost(engine.os.monotonicNanos() - asked);
        if (self.content) |*content| for (self.walkers) |*walker| {
            walker.refresh(self.gpa, &engine.store, &self.walk.world, content, &self.rigs) catch |err|
                log.warn("walker disabled ({t})", .{err});
        };
        if (self.pacer.entity != null) self.refreshPacer(engine);
        self.pacer_block.refresh(self.gpa, &engine.store, &self.walk.world, if (self.content) |*content| content else null);
        self.strafer.refresh(&engine.store, &self.rigs, if (self.content) |*content| content else null);
        // Last, so every body before it keeps the handle it had before M37.
        self.extras.refresh(self.gpa, &engine.store, &self.walk.world, &engine.assets, if (self.content) |*content| content else null);
        // After the corner, for the same reason.
        self.yard.refresh(self.gpa, &engine.store, &self.walk.world, &engine.assets, if (self.content) |*content| content else null, engine.os);
        if (!self.yard_said) if (self.yard.baked_ns) |baked| {
            log.info("collision: addMesh of the hillside, {d} triangles with its baked tree, {d:.3} ms against 5 ms; built at load it took {d:.3} ms", .{ self.yard.triangles, ms(baked), ms(self.yard.built_ns.?) });
            self.yard_said = true;
        };

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

    fn step(self: *Sample, engine: *app.Engine, s: app.Step) !void {
        const dt = s.delta.toSecondsF32();
        // On a tick, so every run asks on the same one. What it loads is only drawn.
        if (s.tick == gallery_mod.request_tick) if (self.gallery.mode.onTick()) |path| {
            if (self.content) |*content| self.gallery.request(content, path, engine.frame_index, engine.os);
        };
        // Writes happen here, outside the frame's window (`runtime-geometry.md` §4.2).
        if (self.corner) |corner| {
            const look: ?[2]Vec3 = if (!self.walk.orbit and self.walk.settings != null) .{ self.walk.eye(), self.walk.rotation().rotate(.init(0, 0, -1)) } else null;
            corner.step(engine, &self.world, s.tick, look);
        }
        self.orbit_angle = wrap(self.orbit_angle + self.settings.orbit_radians_per_second * dt);
        // Before the propagation in the orrery's step, so what it draws is this tick's.
        {
            const pacer_scope = engine.beginScope("animation.advance");
            defer pacer_scope.end();
            const blocks = self.pacer.blocks;
            try self.pacer.step(self.gpa, &self.orrery.world, &self.walk.world, &self.rigs, s.delta.toSecondsF32());
            if (self.pacer.blocks != blocks) log.info("the pacer is blocked at ({d:.3}, {d:.3}) and turns", .{ self.pacer.feet.x, self.pacer.feet.z });
        }
        if (self.animators) |*bench| self.stepAnimators(engine, bench, s.delta.toSecondsF32());
        if (self.strafer.active()) {
            const strafer_scope = engine.beginScope("animation.strafer");
            defer strafer_scope.end();
            try self.strafer.step(&self.rigs, &self.walk.world, if (self.tour == null) self.eye() else null, dt);
        }
        // The game translates `app`'s step into `scene`'s tick: the number and the fixed
        // delta, and nothing a system could read a device through.
        self.orrery.step(.{ .tick = s.tick, .delta = s.delta });
        if (self.pacer.entity != null) {
            // The tour proves the pose replays to the bit, so it has no camera to look at.
            try self.pacer.evaluate(&self.orrery.world, &self.rigs, if (self.tour == null) self.eye() else null, dt);
            if (self.tour != null) try self.pacer_proof.note(self.gpa, &self.pacer, self.orrery);
        }
        if (self.effects) |effects| {
            const moon = if (self.orrery.role(.moon)) |m| scene.hierarchy.worldTransform(&self.orrery.world, m) else null;
            effects.step(engine, s.tick, s.delta.toSecondsF32(), moon);
        }
        if (self.native) |native| if (self.tour != null) try native.record();
        {
            const crowd_scope = engine.beginScope("navigation.crowd");
            defer crowd_scope.end();
            if (self.crowd.step(s.delta.toSecondsF32())) self.navigation.meshes.markDirty();
        }
        // §13: the corner's kinematic pieces move before any character.
        {
            const pieces = engine.beginScope("corner.pieces");
            defer pieces.end();
            if (self.corner_tour) |*ct| {
                if (self.cornerTourReady(engine)) try ct.prepare(&self.walk, &self.extras, engine.os);
            } else if (self.tour == null) try self.extras.step(self.gpa, &self.walk.world, engine.os);
            if (self.extras.sweep_ns) |ns| if (self.sweep_count < self.sweep_times.len) {
                self.sweep_times[self.sweep_count] = ns;
                self.sweep_count += 1;
            };
        }
        // M38's movers, likewise before any character moves.
        {
            const movers = engine.beginScope("yard.movers");
            defer movers.end();
            if (self.yard_tour) |*yt| {
                if (self.yardTourReady()) try yt.prepare(&self.walk, &self.yard, engine.os);
            } else if (self.tour == null) try self.yard.step(self.gpa, &self.walk.world, engine.os);
            if (self.yard.movers_ns) |ns| if (self.yard_tour != null and self.mover_count < self.mover_times.len) {
                self.mover_times[self.mover_count] = ns;
                self.mover_count += 1;
            };
        }
        const scope = engine.beginScope("character");
        defer scope.end();
        const started = engine.os.monotonicNanos(); // Measurement only; never affects the move.
        if (self.tour) |*tour| {
            if (self.yardTourReady()) {
                const yard_started = engine.os.monotonicNanos(); // Measurement only.
                try self.yard_tour.?.move(&self.walk, &self.yard, dt);
                if (self.yard_move_count < self.yard_move_times.len) {
                    self.yard_move_times[self.yard_move_count] = @intCast(engine.os.monotonicNanos() - yard_started);
                    self.yard_move_count += 1;
                }
            }
            if (self.cornerTourReady(engine)) try self.corner_tour.?.move(&self.walk, &self.extras, dt);
            if (!tour.done()) try tour.advance(&self.walk, dt);
            if (tour.done() and tour.failed == null and !self.props_proved and Props.plinthSelected(&engine.store)) {
                try self.props.provePlinth(&self.walk, dt);
                self.props_proved = true;
            }
            if (tour.done() and tour.failed == null) if (self.native) |native| {
                if (native.orbiter_owner != null and native.ticks == Native.proof_ticks and !native.blocked) try native.proveBlocking(&self.walk, dt);
            };
        } else {
            try self.walk.step(if (self.walk.orbit) .{} else self.intent, dt);
            const underfoot = self.walk.surface();
            if (!underfoot.eql(self.underfoot) and !underfoot.isNone()) log.info("walk: on {s}", .{extras_mod.surfaceName(&engine.store, underfoot)});
            self.underfoot = underfoot;
        }
        const elapsed: i64 = @intCast(engine.os.monotonicNanos() - started);
        if (self.move_count < self.move_times.len) {
            self.move_times[self.move_count] = elapsed;
            self.move_count += 1;
        }
        if (self.content != null) {
            if (self.tour != null and self.walkers[0].tick >= Walker.proof_ticks) return;
            for (self.walkers) |*walker| {
                if (self.tour != null and walker.tick >= Walker.proof_ticks) continue;
                try walker.move(self.gpa, &self.walk.world, &self.rigs, dt);
            }
            const animation = engine.beginScope("animation");
            defer animation.end();
            for (self.walkers) |*walker| {
                if (self.tour != null and walker.tick > Walker.proof_ticks) continue;
                try walker.evaluate(&self.rigs);
                if (self.tour != null and walker.tick <= Walker.proof_ticks) walker.record();
            }
        }
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
            // A captured pointer has no position; the kernel is given one outside every panel.
            .pointer = if (engine.input.mouse.captured) .init(-1, -1) else engine.input.mouse.position,
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
            .navigation = self.reportNavigation(),
            .animation = if (self.pacer.entity != null) &self.pacer.report else null,
            .physics = self.reportPhysics(),
        });
    }

    /// Whether M37's stages run this tick: once M23's have passed and the mods' own proofs, which
    /// move the player too, are over, and until they are done.
    fn cornerTourReady(self: *Sample, engine: *app.Engine) bool {
        const ct = &(self.corner_tour orelse return false);
        const tour = self.tour orelse return false;
        if (!tour.done() or tour.failed != null or ct.done()) return false;
        if (Props.plinthSelected(&engine.store) and !self.props_proved) return false;
        if (self.native) |native| if (native.orbiter_owner != null and !native.blocked) return false;
        return true;
    }

    /// Whether M38's stage runs this tick: once M37's six have passed, and until it is done. It
    /// runs before the corner's move in a tick, so it begins on the tick after the corner ends.
    fn yardTourReady(self: *const Sample) bool {
        const yt = self.yard_tour orelse return false;
        const ct = self.corner_tour orelse return false;
        return ct.done() and ct.failed == null and !yt.done();
    }

    /// The walk world's report, with the last tick's work and the yard's move timing.
    fn reportPhysics(self: *Sample) *const physics.Report {
        const now = self.walk.world.report();
        self.physics_report = now;
        // The work since the panel's last frame. The counters wrap, so the difference does too.
        for (&self.physics_report.queries, now.queries, self.physics_last.queries) |*q, a, b| q.* = a -% b;
        inline for (.{ "bodies_visited", "bodies_tested", "triangles_tested", "pairs_closed", "pairs_gjk", "refits" }) |name| {
            @field(self.physics_report, name) = @field(now, name) -% @field(self.physics_last, name);
        }
        self.physics_last = now;
        if (self.yard_move_count > 0) {
            var scratch: [YardTour.max_ticks]i64 = undefined;
            const moves = core.profile.summarise(self.yard_move_times[0..self.yard_move_count], &scratch);
            self.physics_report.move_p95_ms = @floatCast(ms(moves.p95_ns));
        }
        return &self.physics_report;
    }

    fn crateObstacle(self: *const Sample) ?nav_mod.Obstacle {
        const s = self.crowd.settings orelse return null;
        return .{ .half_extents = s.crate_half, .position = self.crowd.cratePosition().? };
    }

    fn reportNavigation(self: *Sample) *const @import("nav").Report {
        self.nav_report = .{};
        if (self.navigation.mesh()) |mesh| self.nav_report.readMesh(mesh);
        self.nav_report.readMeshes(&self.navigation.meshes, self.navigation.current);
        if (self.crowd.crowd) |*crowd| self.nav_report.readCrowd(crowd);
        return &self.nav_report;
    }

    /// The keys, pressed by a person or by `FOUNDRY_SANDBOX3D_KEYS`. Only G is a letter a text
    /// field types, so it alone waits while the overlay's filter box has focus.
    fn keys(self: *Sample, engine: *app.Engine, scripted: Script.Keys) void {
        const in = &engine.input;
        if (in.wasPressed(.f3) or scripted.f3) {
            if (!self.walk.character.isNone()) self.walk.orbit = !self.walk.orbit;
            log.info("f3: {s} camera", .{if (self.walk.orbit) "orbit" else "walk"});
        }
        const typing = self.panels_open and self.ui.wantsKeyboard();
        self.intent = walk_mod.inputIntent(in.*, typing);
        if (in.wasPressed(.f4) or scripted.f4) {
            // Asked from what is true, not from what was last asked: focus loss releases it.
            const want = !in.mouse.captured;
            if (engine.setPointerCapture(want)) |_| {
                log.info("f4: pointer {s}", .{if (want) "captured" else "released"});
            } else |err| {
                log.warn("f4: the pointer cannot be captured here ({t}); look with the arrows or the right button", .{err});
            }
        }
        if (!self.walk.orbit and !typing and (in.mouse.captured or in.mouse.isHeld(.right))) self.walk.look(in.mouse.motion.x, in.mouse.motion.y);
        if (in.wasPressed(.f1) or scripted.f1) {
            self.panels_open = !self.panels_open;
            log.info("debug overlay {s}", .{if (self.panels_open) "shown" else "hidden"});
        }
        if (self.corner) |corner| {
            if ((in.wasPressed(.c) and !typing) or scripted.c) corner.clearCanvas(&self.world);
            if ((in.wasPressed(.t) and !typing) or scripted.t) {
                if (self.walk.teleport(generated.Corner.teleportTarget())) |_| {
                    self.walk.orbit = false;
                    // Facing the canvas, along −X.
                    self.walk.yaw = std.math.pi / 2.0;
                    self.walk.pitch = 0;
                    log.info("t: on the generated corner's patch", .{});
                } else |err| log.warn("t: the player could not be moved ({t})", .{err});
            }
        }
        if (self.effects) |effects| {
            if ((in.wasPressed(.b) and !typing) or scripted.b) effects.burst();
            if ((in.wasPressed(.p) and !typing) or scripted.p) {
                // The patch is M28's: without the generated corner there is nothing to stand on.
                if (self.corner == null) {
                    log.warn("p: the effects are watched from the generated corner's patch, which is off", .{});
                } else if (self.walk.teleport(effects_mod.Effects.teleportTarget())) |_| {
                    self.walk.orbit = false;
                    // Facing the effects, along +Z.
                    self.walk.yaw = std.math.pi;
                    self.walk.pitch = 0;
                    log.info("p: facing the effects corner", .{});
                } else |err| log.warn("p: the player could not be moved ({t})", .{err});
            }
        }
        if ((in.wasPressed(.n) and !typing) or scripted.n) self.navigation.toggle();
        if ((in.wasPressed(.l) and !typing) or scripted.l) {
            if (self.extras.settings == null) {
                log.warn("l: the M37 corner is not there", .{});
            } else if (self.walk.teleport(extras_mod.origin.add(.init(0, 0.005, 0.5)))) |_| {
                self.walk.orbit = false;
                // Facing the ledge, the lift and the turntable, along −Z.
                self.walk.yaw = 0;
                self.walk.pitch = 0;
                log.info("l: in the M37 corner", .{});
            } else |err| log.warn("l: the player could not be moved ({t})", .{err});
        }
        if (in.wasPressed(.y) and !typing) {
            if (self.yard.settings) |ys| {
                const lane = yard_mod.laneZ(yard_mod.middleLane(ys.rows), ys.rows);
                if (self.walk.teleport(self.yard.point(.init(YardTour.start_x, yard_mod.height(YardTour.start_x, lane) + 0.1, lane)))) |_| {
                    self.walk.orbit = false;
                    // Facing along the middle lane, toward the boulder, along +X.
                    self.walk.yaw = -std.math.pi / 2.0;
                    self.walk.pitch = 0;
                    log.info("y: in the M38 yard's middle lane", .{});
                } else |err| log.warn("y: the player could not be moved ({t})", .{err});
            } else log.warn("y: the M38 yard is not there", .{});
        }
        if ((in.wasPressed(.m) and !typing) or scripted.m) {
            self.crowd.moveCrate();
            log.info("m: the crate slides", .{});
        }
        if ((in.wasPressed(.k) and !typing) or scripted.k) {
            if (self.pacer_block.toggle(self.gpa, &self.walk.world)) |_| {
                log.info("k: the pacer's crate {s}", .{if (self.pacer_block.down()) "drops" else "is lifted"});
            } else |err| log.warn("k: the pacer's crate could not drop ({t})", .{err});
        }
        if ((in.wasPressed(.r) and !typing) or scripted.r) {
            log.info("r: reloading every package", .{});
            engine.reloadContent();
        }
        if ((in.wasPressed(.g) and !typing) or scripted.g) if (self.content) |*content| {
            if (self.gallery.model.isNone()) self.gallery.request(content, self.gallery.mode.onKey(), engine.frame_index, engine.os) else self.gallery.release(content);
        };
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
        log.info("f5: the pacer stands at {d:.4},{d:.4},{d:.4}", .{ self.pacer.feet.x, self.pacer.feet.y, self.pacer.feet.z });
        log.info("f5: saved {d} entities ({d} bytes) to the user data directory; poses {x:0>16}", .{
            self.orrery.world.entityCount(), bytes.items.len, hash,
        });
    }

    fn loadWorld(self: *Sample, engine: *app.Engine) void {
        if (self.native) |native| if (!native.canLoadWorld()) {
            log.warn("f9: native registrations cannot survive a world rebuild; restart without native code to load a save", .{});
            return;
        };
        const dir = self.save_dir orelse return;
        const read = engine.os.readFileConfined(self.gpa, dir, save_name, orrery_mod.max_save_bytes) catch |err| {
            log.warn("f9: no save to load ({t})", .{err});
            return;
        };
        defer self.gpa.free(read.bytes);
        const hash = self.orrery.load(read.bytes, &engine.store) orelse {
            self.refreshPacer(engine);
            return;
        };
        // Its character is in the walk world, which no save holds.
        self.refreshPacer(engine);
        log.info("f9: the pacer stands at {d:.4},{d:.4},{d:.4}", .{ self.pacer.feet.x, self.pacer.feet.y, self.pacer.feet.z });
        // The selection was the old world's handle; the save carried the same one.
        self.panels.entities.selected = self.orrery.role(.sheared);
        const same = if (self.saved_hash) |saved| (if (saved == hash) ", the same as this run's save" else ", not this run's save") else "";
        log.info("f9: poses {x:0>16}{s}", .{ hash, same });
    }

    /// The cost run's tick: made the first time the pacer has a rig, then advanced in a span.
    fn stepAnimators(self: *Sample, engine: *app.Engine, bench: *animators_mod.Animators, dt: f32) void {
        if (bench.failed) return;
        if (!bench.built) {
            const e = self.pacer.entity orelse return;
            const animator = scene.animation.animatorOf(&self.orrery.world, e) orelse return;
            bench.start(self.gpa, animator.set, animator.machine, &self.rigs, dt) catch |err| {
                log.warn("animators: not made ({t}); the cost run is off", .{err});
                bench.failed = true;
                return;
            };
            log.info("animators: {d} of the pacer's machine, both layers, advanced with no pose", .{animators_mod.count});
        }
        const scope = engine.beginScope("animation.animators");
        defer scope.end();
        const summary = bench.tick(&self.rigs, dt) catch |err| {
            log.warn("animators: a tick failed ({t}); the cost run is off", .{err});
            bench.failed = true;
            return;
        };
        if (summary.animators != animators_mod.count or summary.unresolved != 0 or summary.lost != 0) {
            log.warn("animators: {d} advanced, {d} unresolved, {d} lost; the cost run is off", .{ summary.animators, summary.unresolved, summary.lost });
            bench.failed = true;
        }
    }

    fn refreshPacer(self: *Sample, engine: *app.Engine) void {
        _ = engine;
        const content = if (self.content) |*c| c else null;
        self.pacer.refresh(self.gpa, &self.orrery.world, self.orrery.role(.pacer), &self.walk.world, content, &self.rigs) catch |err| {
            log.warn("the pacer is disabled ({t})", .{err});
            self.pacer.entity = null;
        };
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
        if (!self.walk.orbit) return self.walk.eye();
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
        const camera: render3d.Camera = .{
            .position = position,
            .rotation = if (!self.walk.orbit) self.walk.rotation() else Quat.lookRotation(focus.sub(position), Vec3.up) orelse Quat.identity,
            .vertical_fov = std.math.pi / 3.2,
            .near = 0.1,
            .far = 80,
        };
        if (self.native) |native| native.host.render3d_camera = .{
            .position = .{ .x = position.x, .y = position.y, .z = position.z },
            .rotation = .{ .x = camera.rotation.x, .y = camera.rotation.y, .z = camera.rotation.z, .w = camera.rotation.w },
            .fov_y = camera.vertical_fov,
            .near = camera.near,
            .far = camera.far,
            .width = pixels.width,
            .height = pixels.height,
        };
        // Rewritten before the window opens, from simulation time (I9), never the clock.
        if (self.corner) |corner| corner.updateWater(engine, &self.world, @as(f32, @floatFromInt(engine.stepper.tick)) * engine.step_delta.toSecondsF32());
        const view: render3d.FrameView = .{
            .camera = camera,
            .target_size = pixels,
            .clear_color = self.settings.clear_linear,
            .ambient = if (!self.shadow_ground.isNone()) .{ 0.15, 0.15, 0.15 } else self.settings.lighting.ambient,
            .exposure_ev100 = if (!self.shadow_ground.isNone()) null else self.settings.lighting.exposure_ev100,
            .shadow_distance = 20,
        };
        // Particle meshes are written here, outside the window, for this frame's camera.
        if (self.effects) |effects| effects.prepare(engine, view);
        if (self.content) |*content| self.navigation.prepare(&self.world, content);
        self.navigation.prepareAgents(&self.world, if (self.crowd.crowd) |*crowd| crowd else null);
        try self.world.begin(view);

        if (!self.shadow_ground.isNone()) {
            try self.world.addLight(.{ .kind = .directional, .intensity = 3, .casts_shadow = true, .world = Mat4.fromQuat(Quat.lookRotation(.init(-1, -2, -1), .up).?) });
            try self.world.drawMesh(.{ .mesh = self.shadow_ground, .material = self.shadow_material, .world = .identity });
            try self.world.drawMesh(.{ .mesh = self.cube, .material = self.cube_material, .world = Mat4.translation(.init(0, 1.2, 0)) });
            try engine.renderScene(.{}, &self.world, null);
            return true;
        }

        // Lights are content values, submitted in authored order. The reader refused
        // an invalid list as a whole before it can reach this frame.
        for (self.settings.lighting.lights[0..self.settings.lighting.len]) |light| try self.world.addLight(light);

        self.drawModel(.{ .model = self.room, .world = Mat4.identity });
        self.drawModel(.{ .model = self.course, .world = Mat4.identity });
        // Drawn only once whole: until then the draw submits nothing (`background.md` §8).
        if (self.content) |*content| self.gallery.poll(content, engine.frame_index, engine.os);
        self.drawModel(.{ .model = self.gallery.model, .world = Mat4.identity });
        if (self.content) |*content| try self.props.draw(content);
        if (self.content) |*content| self.extras.draw(&self.walk.world, content);
        if (self.content) |*content| self.yard.draw(&self.walk.world, content);
        if (self.corner) |corner| try corner.draw(&self.world, &self.content.?);
        if (self.effects) |effects| try effects.draw();
        if (self.content) |*content| try self.crowd.draw(content, self.crate);
        if (self.content) |*content| try self.pacer_block.draw(content);
        if (self.content) |*content| try self.strafer.draw(content);
        try self.navigation.draw(&self.world);
        if (self.content) |*content| for (self.walkers, 0..) |*walker, i| {
            // The sixteen-walker cost run fans their visual instances out. Each still owns
            // an independently sampled pose and collision character; no engine crowd API.
            const offset: Vec3 = if (self.walkers.len == 1) .zero else .init(-@as(f32, @floatFromInt(i % 4)) * 0.65, 0, @as(f32, @floatFromInt(i / 4)) * 0.35);
            try walker.draw(content, offset);
        };
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

        self.pacer.draw(&self.orrery.world, &self.content.?) catch |err|
            log.warn("the pacer could not be drawn ({t})", .{err});

        if (self.native) |native| {
            const scope = engine.beginScope("abi.instances");
            defer scope.end();
            try native.submit(&self.content.?, &self.world);
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
        // What the player stands on (`collision-extras.md` §11), a line above.
        if (!self.walk.orbit and self.walk.settings != null) {
            var under: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&under, "on {s}", .{extras_mod.surfaceName(&engine.store, self.walk.surface())}) catch under[0..0];
            try self.overlay.drawText(font, text, .{ .position = .init(left, bottom - if (self.panels_open) @as(f32, 12) else 20), .scale = if (self.panels_open) 1 else 2 });
        }

        if (self.panels_open) {
            try app.drawUi(&self.ui.list, &self.overlay, .{ .font = font }, .screen, .{});
        }
    }

    /// Opens the panels the last session left open (`debug-overlay.md` §15), and keeps them
    /// at exit.
    fn rememberPanels(self: *Sample, engine: *app.Engine) void {
        self.remembers_panels = true;
        const bytes = engine.readUserFile(self.gpa, panels_file, 4096) orelse return;
        defer self.gpa.free(bytes);
        self.panels.applyState(bytes) catch |err| log.info("the remembered panels are not this build's ({t}); using the defaults", .{err});
    }

    fn deinit(self: *Sample, engine: *app.Engine) void {
        // Before the mesh it borrows.
        self.crowd.deinit(if (self.content) |*c| c else null);
        // It waits for its builds on the pool, and holds a runtime mesh and a material.
        self.navigation.deinit(engine.tasks(), &self.world, if (self.content) |*c| c else null);
        // First: it waits for its work on the pool, and holds content, renderer and walk.
        if (self.corner) |corner| {
            corner.deinit(&self.world, &self.content.?, &self.walk.world);
            self.gpa.destroy(corner);
        }
        // Before `Content`, whose materials it holds.
        if (self.effects) |effects| {
            effects.deinit();
            self.gpa.destroy(effects);
        }
        if (self.content) |*content| self.props.deinit(self.gpa, &self.walk.world, content, &engine.assets);
        self.extras.deinit(self.gpa, &self.walk.world, &engine.assets, if (self.content) |*c| c else null);
        self.yard.deinit(self.gpa, &self.walk.world, &engine.assets, if (self.content) |*c| c else null);
        if (self.content) |*content| for (self.walkers) |*walker| walker.deinit(self.gpa, &self.walk.world, content, &self.rigs);
        self.pacer.deinit(self.gpa, &self.walk.world, if (self.content) |*c| c else null, &self.rigs);
        self.pacer_block.deinit(self.gpa, &self.walk.world, if (self.content) |*c| c else null);
        self.strafer.deinit(&self.rigs, if (self.content) |*c| c else null);
        self.pacer_proof.deinit(self.gpa);
        if (self.animators) |*bench| bench.deinit(self.gpa, &self.rigs);
        self.gpa.free(self.walkers);
        // After what holds a rig, and before the registry it borrows from.
        self.rigs.deinit();
        self.walk.deinit(&engine.assets);
        _ = engine.assets.unregisterLoader(self.gpa, asset.schemas.collision_mesh.id);
        _ = engine.assets.unregisterLoader(self.gpa, asset.schemas.collision_hull.id);
        if (!self.course.isNone()) if (self.content) |*content| content.releaseModel(self.course);
        if (self.content) |*content| self.gallery.release(content);
        if (!self.font_asset.isNone()) engine.assets.release(self.font_asset);
        self.releaseModels();
        self.models.deinit(self.gpa);
        if (self.save_dir) |dir| self.gpa.free(dir);
        if (self.remembers_panels) {
            if (self.panels.encodeState(self.gpa)) |bytes| {
                defer self.gpa.free(bytes);
                engine.writeUserFile(panels_file, bytes);
            } else |err| log.warn("the overlay's panels are not remembered ({t})", .{err});
        }
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
    const Key = enum { f1, f3, f4, f5, f6, f7, f9, g, c, r, t, b, p, n, m, k, l };
    const Keys = struct { f1: bool = false, f3: bool = false, f4: bool = false, f5: bool = false, f6: bool = false, f7: bool = false, f9: bool = false, g: bool = false, c: bool = false, r: bool = false, t: bool = false, b: bool = false, p: bool = false, n: bool = false, m: bool = false, k: bool = false, l: bool = false };

    fn fromEnv(engine: *app.Engine) Script {
        const text = engine.os.envVar("FOUNDRY_SANDBOX3D_KEYS") orelse return .{};
        return parse(text) orelse blk: {
            log.warn("FOUNDRY_SANDBOX3D_KEYS is not a list of key@frame (f1 f3 f4 f5 f6 f7 f9 g c r t b p n m k l); ignoring it", .{});
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

/// A box's vertex-coloured faces, as plain arrays: what M19 wrote by hand, kept so the
/// builder's output can be compared against it (`runtime-geometry.md`, Step 1).
const BoxArrays = struct {
    positions: [24]Vec3,
    normals: [24]Vec3,
    colours: [24][4]u8,
    indices: [36]u16,
};

fn boxArrays(half: Vec3, faces: Faces) BoxArrays {
    var out: BoxArrays = undefined;
    for (face_frames, faces, 0..) |frame, colour, f| {
        const n = scaled(frame[0], half);
        const u = scaled(frame[1], half);
        const v = scaled(frame[2], half);
        const base: u16 = @intCast(f * 4);
        out.positions[base + 0] = n.sub(u).sub(v);
        out.positions[base + 1] = n.add(u).sub(v);
        out.positions[base + 2] = n.add(u).add(v);
        out.positions[base + 3] = n.sub(u).add(v);
        for (out.colours[base..][0..4]) |*c| c.* = colour;
        for (out.normals[base..][0..4]) |*normal| normal.* = frame[0];
        out.indices[f * 6 ..][0..6].* = .{ base, base + 1, base + 2, base, base + 2, base + 3 };
    }
    return out;
}

fn boxMesh(gpa: std.mem.Allocator, half: Vec3, faces: Faces) asset.mesh.BuilderError!asset.OwnedMesh {
    const box = boxArrays(half, faces);
    var builder = asset.MeshBuilder.init(gpa, .default);
    defer builder.deinit();
    try builder.positions(&box.positions);
    try builder.normals(&box.normals);
    try builder.colors8(&box.colours);
    try builder.indices16(&box.indices);
    return builder.finish();
}

fn createBox(world: *render3d.Renderer, half: Vec3, faces: Faces, label: []const u8) !render3d.MeshHandle {
    var owned = try boxMesh(world.gpa, half, faces);
    defer owned.deinit(world.gpa);
    return world.createMesh(owned.mesh, label);
}

fn shadowGroundMesh(gpa: std.mem.Allocator) asset.mesh.BuilderError!asset.OwnedMesh {
    var builder = asset.MeshBuilder.init(gpa, .default);
    defer builder.deinit();
    try builder.positions(&.{ .init(-5, 0, 5), .init(5, 0, 5), .init(5, 0, -5), .init(-5, 0, -5) });
    try builder.normals(&([_]Vec3{.up} ** 4));
    try builder.indices16(&.{ 0, 1, 2, 0, 2, 3 });
    return builder.finish();
}

fn createShadowGround(world: *render3d.Renderer) !render3d.MeshHandle {
    var owned = try shadowGroundMesh(world.gpa);
    defer owned.deinit(world.gpa);
    return world.createMesh(owned.mesh, "shadow proof ground");
}

fn scaled(v: Vec3, by: Vec3) Vec3 {
    return .init(v.x * by.x, v.y * by.y, v.z * by.z);
}

/// Every stream's bytes and the indices, in order: what the GPU is given.
fn meshDigest(mesh: asset.Mesh) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (mesh.streams) |stream| {
        hasher.update(&.{ @intFromEnum(stream.semantic), @intFromEnum(stream.format) });
        hasher.update(stream.bytes);
    }
    hasher.update(mesh.indices);
    hasher.update(std.mem.sliceAsBytes(mesh.submeshes));
    return hasher.final();
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test {
    _ = orrery_mod;
    _ = @import("light_settings.zig");
    _ = walk_mod;
    _ = @import("walk_tests.zig");
    _ = @import("extras_tests.zig");
    _ = @import("yard_tests.zig");
    _ = @import("walker_tests.zig");
    _ = @import("pacer_tests.zig");
    _ = @import("props_tests.zig");
    _ = @import("nav_tests.zig");
    _ = @import("strafer_tests.zig");
    _ = @import("native_tests.zig");
    _ = gallery_mod;
    _ = generated;
    _ = effects_mod;
    _ = @import("effects_tests.zig");
}

test "the builder makes the cube and the proof ground byte for byte as M19 wrote them" {
    var cube = try boxMesh(testing.allocator, .init(0.6, 0.6, 0.6), cube_faces);
    defer cube.deinit(testing.allocator);
    const box = boxArrays(.init(0.6, 0.6, 0.6), cube_faces);
    const hand = [_]asset.MeshStream{
        .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&box.positions) },
        .{ .semantic = .normal, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&box.normals) },
        .{ .semantic = .color, .format = .unorm8x4, .bytes = std.mem.sliceAsBytes(&box.colours) },
    };
    try testing.expectEqual(hand.len, cube.mesh.streams.len);
    for (hand, cube.mesh.streams) |want, have| {
        try testing.expectEqual(want.semantic, have.semantic);
        try testing.expectEqual(want.format, have.format);
        try testing.expectEqualSlices(u8, want.bytes, have.bytes);
    }
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&box.indices), cube.mesh.indices);
    try testing.expectEqual(try asset.Mesh.computeBounds(&box.positions), cube.mesh.bounds);
    try testing.expectEqual(@as(u64, 16753803297239917816), meshDigest(cube.mesh));

    var ground = try shadowGroundMesh(testing.allocator);
    defer ground.deinit(testing.allocator);
    const ground_positions = [_]Vec3{ .init(-5, 0, 5), .init(5, 0, 5), .init(5, 0, -5), .init(-5, 0, -5) };
    const ground_normals = [_]Vec3{.up} ** 4;
    const ground_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&ground_positions), ground.mesh.streams[0].bytes);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&ground_normals), ground.mesh.streams[1].bytes);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&ground_indices), ground.mesh.indices);
    try testing.expectEqual(@as(u64, 6219219726740329206), meshDigest(ground.mesh));
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

test "sample proof switches are explicit and the last setting given wins" {
    var options: Options = .{};
    try testing.expectEqual(@as(u32, 4), options.sample_count);
    try testing.expect(options.cull);
    try testing.expect(options.shadows);
    try testing.expect(options.parse("--shadows=off"));
    try testing.expect(!options.shadows);
    try testing.expect(!options.shadow_proof);
    try testing.expect(options.parse("--shadow-proof"));
    try testing.expect(options.shadow_proof);
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
