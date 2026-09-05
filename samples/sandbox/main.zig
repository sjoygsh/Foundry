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
const data = @import("data");
const platform = @import("platform");
const render2d = @import("render2d");
const rhi = @import("rhi");
const scene = @import("scene");

/// Routes Foundry's logging through the engine's sink. One line, in the root source file.
pub const std_options = app.std_options;

const log = core.log.scoped(.sandbox);

/// What the sandbox loads, **in load order**.
///
/// Package zero first (I3): Foundry's own content, through the same call and the same
/// format the sample's package uses. Then the sample's own, which is what a game ships —
/// and where anything the sample draws is described.
///
/// Both are compiled by `fpack` during the build and installed under `<prefix>/content`,
/// which is where the engine looks by default. A third package placed after these
/// overrides either of them by content id, without knowing where their files are.
const content_packages = [_]app.ContentPackage{
    .{ .file = "core.fpk", .root = "core" },
    .{ .file = "sandbox.fpk", .root = "sandbox" },
};

/// The built-ins, plus whatever `FOUNDRY_SANDBOX_PACKAGES` names, in that order.
///
/// **This is the mod path, with no mod manager in front of it.** Compile a package with
/// `fpack` into `<prefix>/content`, name it here, and it loads after the base game and
/// overrides by content id — which is the whole of Tier 1 modding working long before the
/// mod system exists (CLAUDE.md §5). Discovering packages rather than being told about
/// them is M7's job, and a sample inventing a discovery rule would be answering it early.
///
/// The result borrows nothing from the caller and is freed by it. `Engine.init` copies
/// what it keeps.
fn contentPackages(gpa: std.mem.Allocator, env: []const platform.os.EnvVar) ![]app.ContentPackage {
    var list: std.ArrayList(app.ContentPackage) = .empty;
    errdefer freePackages(gpa, list.items);
    errdefer list.deinit(gpa);

    for (content_packages) |pkg| try list.append(gpa, .{
        .file = try gpa.dupe(u8, pkg.file),
        .root = try gpa.dupe(u8, pkg.root),
    });

    const extra = for (env) |v| {
        if (std.mem.eql(u8, v.name, "FOUNDRY_SANDBOX_PACKAGES")) break v.value;
    } else return list.toOwnedSlice(gpa);

    var it = std.mem.splitScalar(u8, extra, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0) continue;
        // A location, not an identity, and therefore checked as one: a stem that could
        // climb out of the content directory is refused rather than joined.
        if (!platform.os.isSafeRelativePath(name)) {
            log.warn("FOUNDRY_SANDBOX_PACKAGES: '{s}' is not a package name", .{name});
            continue;
        }
        log.info("extra content package: '{s}'", .{name});
        try list.append(gpa, .{
            .file = try std.fmt.allocPrint(gpa, "{s}.fpk", .{name}),
            .root = try gpa.dupe(u8, name),
        });
    }
    return list.toOwnedSlice(gpa);
}

fn freePackages(gpa: std.mem.Allocator, packages: []const app.ContentPackage) void {
    for (packages) |pkg| {
        gpa.free(pkg.file);
        gpa.free(pkg.root);
    }
}

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

    const packages = try contentPackages(gpa, env);
    defer {
        freePackages(gpa, packages);
        gpa.free(packages);
    }

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
        .content = packages,
    });
    defer engine.deinit();

    // The renderer and its sprites, created once and torn down explicitly. Unlike M1's
    // quad, this *does* have a teardown: `Renderer.deinit` idles the device first, which
    // is what `rhi.waitIdle` was added for.
    var field = try SpriteField.init(gpa, engine.gpu);
    defer field.deinit(engine);
    try field.load(engine);
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
        if (field.save_path) |path| {
            log.info("F5 saves the world to '{s}'; F9 loads it back", .{path});
        }
    }

    var reported_tick: u64 = 0;
    var size_index: usize = 0;
    const auto_resize_every = everyFrames(engine, "FOUNDRY_SANDBOX_RESIZE_EVERY");

    while (!engine.shouldQuit()) {
        engine.beginFrame();

        // Immediately after `beginFrame`, which is where a hot reload happens. Anything the
        // sample derived from content is derived again here, before the frame reads it.
        field.refresh(engine);

        while (engine.nextEvent()) |ev| report(ev);

        while (engine.nextStep()) |step| {
            // The only place simulation happens. It reads `step.input`, never the device.
            if (step.input.wasPressed(.escape)) engine.requestQuit();

            // And the world advances here, once per fixed step, for the same reason.
            field.step(step);

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
        // a draw list; the engine owns the frame and the pass. What it draws is whatever
        // the last simulation step left in the world — no interpolation between the two
        // most recent transforms yet, which is what `engine.alpha()` is for and what the
        // world now finally has the two states to make possible.
        field.control(engine);
        try field.submit(engine);

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

    // On the way out, so a scripted run leaves a save behind for the next one to read.
    // That is the only honest check that a world survives a *restart* rather than a round
    // trip through memory in one process.
    if (field.save_path) |path| field.saveWorld(engine, path);

    log.info("clean exit after {d} frames, {d} ticks, {d}ms simulated", .{
        engine.frame_index,
        engine.stepper.tick,
        engine.elapsed().toMillis(),
    });
}

/// Everything the sample draws with, read from content rather than written here.
///
/// **This is the sample's half of I3.** The sandbox ships its own package —
/// `samples/sandbox/content/`, compiled to `sandbox.fpk` — loaded after Foundry's package
/// zero through the same call, with no privileged path either way. A game does exactly
/// this, which is what makes the sample worth having as a reference (ADR-0017).
///
/// Nothing here is a path. The record names two asset ids and the registry answers; the
/// sample cannot ask what is at a path even if it wanted to (ADR-0021).
const Settings = struct {
    sprites: u32,
    grid: u32,
    /// Borrowed from the package's own bytes, which the engine keeps for its lifetime.
    banner: []const u8,
    sheet: core.ContentId,
    font: core.ContentId,

    /// Where the record is, and the only content id spelled in this file. Everything else
    /// the sample draws is reached through it.
    const id = "sandbox:settings.main";

    const fallback: Settings = .{
        .sprites = 4000,
        .grid = 4,
        .banner = "",
        .sheet = .none,
        .font = .none,
    };

    /// Reads the record, falling back field by field.
    ///
    /// **Content is untrusted, including our own** (CLAUDE.md §5). A package that a mod has
    /// replaced can be missing, malformed or a different shape, and none of that is a
    /// reason for a sample to crash — so every read has an answer and a bad one is a log
    /// line, not an assertion.
    fn read(engine: *app.Engine) Settings {
        const record = engine.store.lookup(core.ContentId.fromString(id)) orelse {
            log.err("'{s}' is not in any loaded package; drawing defaults", .{id});
            return fallback;
        };

        return .{
            .sprites = intField(record, "sprites", fallback.sprites),
            .grid = intField(record, "grid", fallback.grid),
            .banner = stringField(record, "banner", fallback.banner),
            .sheet = idField(record, "sheet"),
            .font = idField(record, "font"),
        };
    }

    fn intField(record: data.store.Record, name: []const u8, fallback_value: u32) u32 {
        const index = record.schema.fieldIndex(name) orelse return fallback_value;
        const value = (record.fields.intAt(index) catch null) orelse return fallback_value;
        if (value < 0 or value > std.math.maxInt(u32)) return fallback_value;
        return @intCast(value);
    }

    fn stringField(record: data.store.Record, name: []const u8, fallback_value: []const u8) []const u8 {
        const index = record.schema.fieldIndex(name) orelse return fallback_value;
        return (record.fields.stringAt(index) catch null) orelse fallback_value;
    }

    fn idField(record: data.store.Record, name: []const u8) core.ContentId {
        const index = record.schema.fieldIndex(name) orelse return .none;
        return (record.fields.idAt(index) catch null) orelse .none;
    }
};

/// What the sandbox's entities are made of.
///
/// **A game defines its own component types**, and these are the sample's. They are
/// declared here rather than in the engine because `CLAUDE.md` I5 says so: the engine
/// provides mechanisms and content provides specifics, and "a thing that orbits a point" is
/// a specific if anything is.
///
/// Each is an ordinary Zig struct with a name. `scene.componentType` derives the schema, the
/// deserializer and the constructor from it — and produces the same registration data a mod
/// would fill in through the C ABI (ADR-0010), which is why registering one looks like
/// nothing special.
const Orbit = struct {
    pub const component = "sandbox:orbit";
    home_x: f32 = 0,
    home_y: f32 = 0,
    radius: f32 = 0,
    speed: f32 = 0,
    phase: f32 = 0,
    spin: f32 = 0,
};

/// Where a thing is. Written by the orbit system every tick, read by the draw code.
const Transform = struct {
    pub const component = "sandbox:transform";
    x: f32 = 0,
    y: f32 = 0,
    rotation: f32 = 0,
};

/// What it looks like. `render2d.Color` derives as an inline struct, which is the shape
/// `content-schemas.md` §3 prefers over a colour type — four named values with no identity
/// of their own.
const Visual = struct {
    pub const component = "sandbox:visual";
    size: f32 = 16,
    cell: u32 = 0,
    tint: render2d.Color = .{},
    additive: bool = false,
    /// `render2d.Sprite.layer` is an `i16`; the content type list has `i32`, and narrowing
    /// at the draw call is cheaper than a type nobody else would want.
    layer: i32 = 0,
};

/// Advances every orbiting entity's transform. **The sandbox's whole simulation.**
///
/// It reads no clock and no input, because `scene` cannot: it is handed the tick, and the
/// angle is a function of the tick number and the fixed delta. That makes the field's motion
/// reproducible by construction rather than by care (I9) — the same run produces the same
/// positions, on any machine fast or slow.
fn orbitSystem(_: ?*anyopaque, world: *scene.World, tick: scene.Tick) void {
    const seconds = @as(f32, @floatFromInt(tick.tick)) * tick.delta.toSecondsF32();

    var it = world.queryOf(.{ Orbit, Transform });
    while (it.next()) |m| {
        const orbit = m.get(Orbit);
        const transform = m.get(Transform);
        const angle = orbit.phase + seconds * orbit.speed;
        transform.x = orbit.home_x + @cos(angle) * orbit.radius;
        transform.y = orbit.home_y + @sin(angle) * orbit.radius;
        transform.rotation = angle * orbit.spin;
    }
}

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
    settings: Settings,

    /// The two assets, held as **asset** handles rather than texture handles.
    ///
    /// What the registry gave out is what it takes back, and holding the asset handle is
    /// what keeps the reference count honest. The texture handle is derived from it where
    /// it is needed, which is also how hot reload will get to swap one without this struct
    /// noticing (step 10).
    sheet_asset: asset.AssetHandle,
    font_asset: asset.AssetHandle,

    /// The sheet's grid, as a region. Cells come from `Region.sub`, which cuts in the
    /// *region's* pixel space — so this code is identical whether the sheet is standalone
    /// or packed into something larger later.
    sheet: render2d.Region,
    /// An 8-pixel white patch, built in memory rather than loaded, stretched into thin
    /// quads to draw the selection outline and the HUD panels.
    ///
    /// **Not content, and that is the point.** A game generating an image at runtime is a
    /// capability worth keeping exercised, and `createTexture` takes an `asset.Image`
    /// whatever made it. The sample addresses the middle four pixels of the eight rather
    /// than the whole thing, so a sample that strays lands on more white.
    blank_texture: render2d.TextureHandle,
    blank: render2d.Region,
    font: render2d.BitmapFont,

    /// **The world, and the schema registry it borrows.**
    ///
    /// The registry is the sample's own rather than the engine's, and that is not an
    /// oversight: hot reload builds a whole new content set with a whole new `data.Registry`
    /// and swaps it (`app-and-frame-loop.md` §8), so a world holding a pointer into the
    /// engine's would be holding a freed one the moment somebody saved a file. Component
    /// schemas are declared by code and outlive any reload, which is exactly the difference.
    schemas: data.Registry,
    world: scene.World,
    orbit: scene.ComponentType = .none,
    transform: scene.ComponentType = .none,
    visual: scene.ComponentType = .none,
    /// How many entities the field currently has, kept for the log lines that used to
    /// report the seed count.
    population: u32 = 0,

    /// The content generation this was last built against.
    ///
    /// Hot reload swaps what a handle points at, so the handles above survive; what does
    /// not survive is anything *derived* — the regions, and every string borrowed from a
    /// package's bytes. Comparing this to `engine.contentGeneration()` is how the sample
    /// knows to derive them again.
    content_generation: u64 = 0,
    /// **A copy, not a borrow.** The record's string lives in the package's bytes, which a
    /// reload frees; a sample holding one across a reload would be reading freed memory
    /// between the swap and the next refresh. Copy what you keep.
    banner_buf: [256]u8 = undefined,
    banner_len: usize = 0,

    /// Driven by input, so it is state rather than something recomputed per frame.
    camera: render2d.Camera2D,
    /// Which sprite was last clicked. Presentation only: nothing in the simulation reads
    /// it. A handle rather than an index, so a stale one fails cleanly — the field can be
    /// rebuilt under a selection by a content reload (I1).
    selected: ?scene.Entity = null,
    /// Pick at the window's centre every N frames, or null to only pick on a click.
    /// Same rationale as `FOUNDRY_SANDBOX_RESIZE_EVERY`: a windowed path that cannot be
    /// scripted is a path that only gets checked when someone remembers to check it.
    pick_every: ?u64 = null,

    /// Where F5 writes and F9 reads, from `FOUNDRY_SANDBOX_SAVE`.
    ///
    /// Borrowed from the environment, which outlives the field. When it is set the sample
    /// also saves on the way out, so one scripted run writes a world and the next reads it
    /// — which is the only honest way to check that a save survives a *restart* rather
    /// than merely a round trip in memory.
    save_path: ?[]const u8 = null,

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

    /// A bound on a save this sample will read. Untrusted input is bounded at the
    /// boundary: `readFile` insists on a number, and this is the sample's.
    const max_save_bytes: usize = 64 * 1024 * 1024;

    /// The renderer and nothing else. Content arrives in `load`, which needs this struct
    /// to already be where it is going to live.
    fn init(gpa: std.mem.Allocator, device: *rhi.Device) !SpriteField {
        var renderer = try render2d.Renderer.init(gpa, device, .{
            .frames_in_flight = 2,
        });
        errdefer renderer.deinit();

        return .{
            .gpa = gpa,
            .renderer = renderer,
            .settings = Settings.fallback,
            .sheet_asset = .none,
            .font_asset = .none,
            .sheet = .{ .texture = .none, .uv = .{}, .size_px = .{} },
            .blank_texture = .none,
            .blank = .{ .texture = .none, .uv = .{}, .size_px = .{} },
            .font = .{
                .glyphs = .{ .texture = .none, .uv = .{}, .size_px = .{} },
                .cell = .{ .width = 8, .height = 8 },
                .columns = 16,
                .glyph_count = 95,
            },
            // Both are placeholders: `World.init` needs the registry's final address, and
            // this struct is returned by value, so the world is built in `load`.
            .schemas = undefined,
            .world = undefined,
            .camera = .{ .viewport = .init(0, 0, 1280, 720) },
        };
    }

    /// Registers the texture loader, reads the settings record, and acquires what it names.
    ///
    /// **Separate from `init` because the loader borrows `&self.renderer`**, and a renderer
    /// returned by value has not reached its final address yet. Registering against a
    /// pointer into a temporary is a bug that would work for a while.
    ///
    /// This is also the whole of what a game does with the asset system: hand up the loader
    /// that knows what a texture is, then ask for content ids. It never names a file.
    fn load(self: *SpriteField, engine: *app.Engine) !void {
        const gpa = self.gpa;

        // The capability points up, the dependency points down (I6). `app` has no
        // `render2d`, so the engine could not have done this itself — and a mod adding an
        // asset kind the engine has never heard of makes exactly this call.
        try engine.assets.registerLoader(gpa, render2d.textureLoader(&self.renderer));

        self.readSettings(engine);

        self.sheet_asset = try engine.assets.acquire(gpa, self.settings.sheet);
        self.font_asset = try engine.assets.acquire(gpa, self.settings.font);
        self.font = .{
            .glyphs = .{ .texture = .none, .uv = .{}, .size_px = .{} },
            .cell = .{ .width = 8, .height = 8 },
            .columns = 16,
            .first_codepoint = ' ',
            .glyph_count = 95,
        };
        self.deriveRegions(engine);
        self.content_generation = engine.contentGeneration();

        // An image from memory, not from a file: `createTexture` takes an `asset.Image`
        // and does not care what made it, which is what lets a game generate one.
        var white = try asset.Image.alloc(gpa, 8, 8);
        defer white.deinit(gpa);
        @memset(white.pixels, 0xFF);
        self.blank_texture = try self.renderer.createTexture(white, .{ .label = "sandbox blank" });
        self.blank = self.renderer.textureRegion(self.blank_texture).?.sub(2, 2, 4, 4);

        // The world, and the three component types the sample defines. Registration happens
        // before any entity exists, which `scene` insists on: storage is allocated per type,
        // and a type arriving later would have no data for what is already there.
        self.schemas = .init(gpa, .default);
        self.world = .init(gpa, &self.schemas, .default);
        try self.registerTypes();
        self.save_path = engine.os.envVar("FOUNDRY_SANDBOX_SAVE");

        const count = spriteCount(engine, self.settings.sprites);
        log.info("content: sheet {d}x{d}, glyphs {d}x{d}, {d} sprites, grid {d}", .{
            self.sheet.size_px.width,       self.sheet.size_px.height,
            self.font.glyphs.size_px.width, self.font.glyphs.size_px.height,
            count,                          self.settings.grid,
        });

        // A save is a whole world, so it replaces the generated field rather than adding
        // to it. Absent, unreadable or refused, the sample builds the field it always did
        // — a missing save is a first run, not a failure.
        const restored = if (engine.os.envVar("FOUNDRY_SANDBOX_LOAD")) |path|
            self.loadWorld(engine, path)
        else
            false;
        if (!restored) try self.populate(count);
    }

    /// The component types and systems this sample defines.
    ///
    /// Its own file would be the game's; here it is three structs and one function. Split
    /// out because a load rebuilds the world, and registration is refused once a world has
    /// entities — so this is the part that has to happen again and `populate` is the part
    /// that must not.
    fn registerTypes(self: *SpriteField) !void {
        self.orbit = try self.world.registerComponent(scene.componentType(Orbit));
        self.transform = try self.world.registerComponent(scene.componentType(Transform));
        self.visual = try self.world.registerComponent(scene.componentType(Visual));
        _ = try self.world.registerSystem(.{
            .id = try data.contentId("sandbox:system.orbit"),
            .name = "sandbox:system.orbit",
            .update = &orbitSystem,
        });
    }

    /// Throws the world away and builds an empty one with the same types registered.
    ///
    /// A save carries absolute entity handles and loads into a **fresh** world
    /// (`entity-storage.md` §9), so reloading at runtime is a rebuild rather than a merge.
    /// Merging one into a populated world is a different operation with different rules,
    /// and it is not owed anything yet.
    fn rebuildWorld(self: *SpriteField) !void {
        self.world.deinit();
        self.schemas.deinit(self.gpa);
        self.schemas = .init(self.gpa, .default);
        self.world = .init(self.gpa, &self.schemas, .default);
        try self.registerTypes();
        self.selected = null;
        self.population = 0;
    }

    /// Writes the world to `path`.
    ///
    /// **`scene` cannot open a file**, so it produces bytes and the sample writes them.
    /// That is the same split `data` lives under and it is why every test of the save
    /// format is hermetic.
    fn saveWorld(self: *SpriteField, engine: *app.Engine, path: []const u8) void {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.gpa);
        self.world.save(&bytes) catch |err| {
            log.warn("could not build a save: {t}", .{err});
            return;
        };
        engine.os.writeFile(path, bytes.items) catch |err| {
            log.warn("could not write '{s}': {t}", .{ path, err });
            return;
        };
        log.info("saved {d} entities to '{s}' ({d} bytes)", .{
            self.world.entityCount(), path, bytes.items.len,
        });
    }

    /// Replaces the world with the one in `path`. False if there was nothing to load.
    ///
    /// The file is read **before** the world is torn down, so a missing or unreadable save
    /// leaves what is on screen alone. Once the rebuild has happened a refused save leaves
    /// an empty world, and the caller repopulates.
    fn loadWorld(self: *SpriteField, engine: *app.Engine, path: []const u8) bool {
        const bytes = engine.os.readFile(self.gpa, path, max_save_bytes) catch |err| {
            if (err != error.FileNotFound) log.warn("could not read '{s}': {t}", .{ path, err });
            return false;
        };
        defer self.gpa.free(bytes);

        self.rebuildWorld() catch |err| {
            log.warn("could not rebuild the world: {t}", .{err});
            return false;
        };
        const summary = self.world.load(bytes, .default) catch |err| {
            log.warn("'{s}' was refused: {t}", .{ path, err });
            return false;
        };
        self.population = summary.entities;
        log.info("loaded {d} entities and {d} components from '{s}'{s}", .{
            summary.entities,
            summary.components,
            path,
            if (summary.skipped_types == 0) "" else " (some component types were skipped)",
        });
        return true;
    }

    /// One fixed simulation step. The game translates `app`'s step into `scene`'s tick.
    ///
    /// The two are deliberately different types. `app.Step` carries the frame's input
    /// snapshot and the elapsed total; a system is entitled to the tick number and the fixed
    /// delta and nothing else, which is what makes a simulation reproducible and what stops
    /// it reading a device (`entity-storage.md` §7).
    fn step(self: *SpriteField, s: app.Step) void {
        self.world.update(.{ .tick = s.tick, .delta = s.delta });
    }

    /// Rebuilds everything **derived** from content, if content has moved since last time.
    ///
    /// **Called every frame, right after `beginFrame`** — which is where a reload happens,
    /// so nothing gets to read a stale derivation. `assets.md` §4 promises that a handle
    /// follows a swap on its own, and it does; a `Region` cut from a texture and a string
    /// borrowed from a package's bytes are not handles, and this is the other half of that
    /// promise being kept by the caller.
    ///
    /// Nothing here can fail the frame. A content edit that names a missing asset keeps
    /// what was working and says so, which is the same bargain `§6` rule 2 makes one layer
    /// down.
    fn refresh(self: *SpriteField, engine: *app.Engine) void {
        const generation = engine.contentGeneration();
        if (generation == self.content_generation) return;
        self.content_generation = generation;

        const previous = self.settings;
        self.readSettings(engine);

        // Only if the record now names a *different* asset. An asset whose bytes changed
        // keeps its handle, which is the whole point of holding one.
        self.reacquire(engine, &self.sheet_asset, previous.sheet, self.settings.sheet);
        self.reacquire(engine, &self.font_asset, previous.font, self.settings.font);
        self.deriveRegions(engine);

        if (self.settings.sprites != previous.sprites) {
            const count = spriteCount(engine, self.settings.sprites);
            if (count != self.population) {
                self.populate(count) catch |err| {
                    log.warn("could not resize the field to {d} ({t}); keeping {d}", .{
                        count, err, self.population,
                    });
                    return;
                };
                // The selection referred to an entity that no longer exists. Clearing it is
                // tidiness rather than safety — a stale handle already resolves to nothing.
                self.selected = null;
            }
        }
        log.info("content changed: {d} sprites, grid {d}", .{ self.population, self.settings.grid });
    }

    fn readSettings(self: *SpriteField, engine: *app.Engine) void {
        self.settings = Settings.read(engine);
        const text = self.settings.banner;
        self.banner_len = @min(text.len, self.banner_buf.len);
        @memcpy(self.banner_buf[0..self.banner_len], text[0..self.banner_len]);
    }

    /// The regions the drawing code cuts from, re-derived from whatever the handles point
    /// at now.
    fn deriveRegions(self: *SpriteField, engine: *app.Engine) void {
        if (self.renderer.textureRegion(self.textureOf(engine, self.sheet_asset))) |region| {
            self.sheet = region;
        }
        if (self.renderer.textureRegion(self.textureOf(engine, self.font_asset))) |region| {
            self.font.glyphs = region;
        }
    }

    fn reacquire(
        self: *SpriteField,
        engine: *app.Engine,
        handle: *asset.AssetHandle,
        before: core.ContentId,
        after: core.ContentId,
    ) void {
        if (before.eql(after)) return;
        const fresh = engine.assets.acquire(self.gpa, after) catch |err| {
            log.warn("content now asks for {f}, which did not load ({t}); keeping the old one", .{ after, err });
            return;
        };
        engine.assets.release(handle.*);
        handle.* = fresh;
    }

    /// The texture behind an asset handle.
    ///
    /// The registry holds a loader's product as one opaque word and never looks inside; the
    /// module that put a `TextureHandle` there is the one that may take it back out.
    fn textureOf(self: *SpriteField, engine: *app.Engine, handle: asset.AssetHandle) render2d.TextureHandle {
        _ = self;
        const payload = engine.assets.payloadOf(handle) orelse return .none;
        return payload.asHandle(render2d.TextureHandle);
    }

    /// Rebuilds the field: every entity destroyed, `count` fresh ones created.
    ///
    /// The parameters come from one seeded generator run here, exactly as they did when
    /// this was an array of seeds — the difference is where they land. They used to be a
    /// struct the draw code indexed; they are now three components on an entity, and the
    /// motion that used to be recomputed from `seconds` at every draw is a system that runs
    /// once per tick.
    fn populate(self: *SpriteField, count: u32) !void {
        // Destroy first, and all of it: `populate` is also the reload path, so it has to
        // leave nothing of the previous field behind. `destroy` clears every component
        // store, so this is the whole of it.
        var old_entities: std.ArrayList(scene.Entity) = .empty;
        defer old_entities.deinit(self.gpa);
        {
            var it = self.world.query(&.{self.transform});
            while (it.next()) |e| try old_entities.append(self.gpa, e);
        }
        for (old_entities.items) |e| _ = self.world.destroy(e);

        // Explicit seed and stream, never the clock: the same build draws the same field
        // on every run, which is what makes a visual difference mean something.
        var rng: core.rng.Pcg32 = .init(0x5EED_5A11_D0_1234, 1);
        for (0..count) |index| {
            const entity = try self.world.create();
            const cell = rng.below(16);

            var orbit: Orbit = .{
                .home_x = (rng.float01() - 0.5) * 1400,
                .home_y = (rng.float01() - 0.5) * 900,
                .radius = 10 + rng.float01() * 90,
                .speed = 0.2 + rng.float01() * 1.1,
                .phase = rng.float01() * std.math.tau,
                .spin = (rng.float01() - 0.5) * 2.0,
            };
            var visual: Visual = .{
                .size = 14 + rng.float01() * 26,
                .cell = cell,
                .tint = .srgb8(255, 255, 255, 160 + @as(u8, @intCast(rng.below(96)))),
                // A tenth of them additive, so both pipelines are on screen and a
                // regression in either is visible rather than theoretical.
                .additive = rng.below(10) == 0,
                .layer = 0,
            };
            // Four layers, so the sort is doing real work rather than sorting a constant.
            // Additive sprites ride on top, where they belong.
            visual.layer = if (visual.additive) 3 else @intCast(index % 3);

            _ = try self.world.addComponent(entity, self.orbit, std.mem.asBytes(&orbit));
            _ = try self.world.addComponent(entity, self.visual, std.mem.asBytes(&visual));
            // Zeroed until the first tick runs the system. The order the components are
            // added in is the order the stores hold them, and drawing iterates the
            // transform store, so this is also the draw order.
            _ = try self.world.addComponent(entity, self.transform, null);
        }
        self.population = count;

        // One step's worth, so the field has positions before the first frame draws it
        // rather than a frame of everything at the origin.
        self.world.update(.{ .tick = 0, .delta = .fromMillis(0) });
    }

    /// **The asset loader goes back before the renderer does.**
    ///
    /// `unregisterLoader` hands every texture this renderer made back to it while it still
    /// exists. Without it the engine's registry would unload through a `*Renderer` that had
    /// already been torn down — a teardown-order bug the compiler cannot see, and the
    /// reason that call exists.
    fn deinit(self: *SpriteField, engine: *app.Engine) void {
        engine.assets.release(self.sheet_asset);
        engine.assets.release(self.font_asset);
        _ = engine.assets.unregisterLoader(self.gpa, asset.schemas.texture.id);

        self.world.deinit();
        self.schemas.deinit(self.gpa);
        self.renderer.deinit();
    }

    /// What one sprite looks like right now.
    ///
    /// **One definition, used by both drawing and picking.** Two would agree until the
    /// day one of them changed, and the symptom would be clicks landing next to sprites
    /// rather than on them — which is exactly the sort of bug that gets blamed on the
    /// maths instead of on the duplication.
    fn spriteOf(self: *const SpriteField, transform: *const Transform, visual: *const Visual) render2d.Sprite {
        // In the sheet's own pixels, not the atlas's. `Region.sub` is what makes that
        // possible, and it is why the sheet being its own texture rather than part of
        // something larger changes nothing here.
        const grid = @max(self.settings.grid, 1);
        const cell_w = self.sheet.size_px.width / grid;
        const cell_h = self.sheet.size_px.height / grid;
        const cell = self.sheet.sub(
            (visual.cell % grid) * cell_w,
            (visual.cell / grid) * cell_h,
            cell_w,
            cell_h,
        );

        return .{
            .texture = cell.texture,
            .position = .init(transform.x, transform.y),
            .size = .init(visual.size, visual.size),
            .uv = cell.uv,
            .rotation = transform.rotation,
            .tint = visual.tint,
            .blend = if (visual.additive) .additive else .alpha,
            .layer = @intCast(visual.layer),
        };
    }

    /// The sprite for one entity, or null if it is not one of the field's.
    ///
    /// Used by the selection, which holds an entity rather than an index and therefore has
    /// to ask. A stale handle answers null, which is exactly the behaviour that makes
    /// holding one safe across a content reload.
    fn spriteFor(self: *SpriteField, entity: scene.Entity) ?render2d.Sprite {
        const transform = self.world.getComponent(entity, self.transform) orelse return null;
        const visual = self.world.getComponent(entity, self.visual) orelse return null;
        return self.spriteOf(
            @ptrCast(@alignCast(transform.ptr)),
            @ptrCast(@alignCast(visual.ptr)),
        );
    }

    /// Camera control and picking — the sample's input policy, and the half of "a 2D
    /// camera with pan and zoom" that is not maths.
    ///
    /// Outside the fixed step, like resizing and for the same reason: where the camera
    /// is looking is presentation, not simulation. That is also why it may use
    /// `frameDelta` — a wall-clock number that simulation is forbidden to touch (I9).
    fn control(self: *SpriteField, engine: *app.Engine) void {
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

        // The whole world to a file and back, through the same path a scripted run uses.
        if (self.save_path) |path| {
            if (in.wasPressed(.f5)) self.saveWorld(engine, path);
            if (in.wasPressed(.f9) and !self.loadWorld(engine, path)) {
                self.populate(spriteCount(engine, self.settings.sprites)) catch |err| {
                    log.warn("could not rebuild the field: {t}", .{err});
                };
            }
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
            self.selected = self.pick(world);
            if (self.selected) |entity| {
                log.info("picked entity {d}#{d} of {d} at world ({d:.1}, {d:.1}), zoom {d:.2}", .{
                    entity.index, entity.generation, self.population,
                    world.x,      world.y,           self.camera.zoom,
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
    fn pick(self: *SpriteField, world: core.math.Vec2) ?scene.Entity {
        var best: ?scene.Entity = null;
        var best_layer: i16 = 0;

        var it = self.world.queryOf(.{ Transform, Visual });
        while (it.next()) |m| {
            const sprite = self.spriteOf(m.get(Transform), m.get(Visual));
            // World space, so `.up` — the sample's picking is of world sprites.
            if (!render2d.containsPoint(sprite, world, .up)) continue;
            // Later in the draw order wins, and the draw order is `(layer, submission
            // index)` — the batcher's own sort key. So "topmost" means the same thing to
            // the pick as it does to the GPU, rather than being a second guess at it.
            //
            // This scan and the one in `submit` name the same components in the same order,
            // which is what keeps "later in the draw order" true: the query's order is a
            // property of how it is written (`entity-storage.md` §5).
            if (best == null or sprite.layer >= best_layer) {
                best = m.entity;
                best_layer = sprite.layer;
            }
        }
        return best;
    }

    /// Builds this frame's draw list. This is the game's half of rendering, and it never
    /// sees a command buffer or a render pass: `app.Engine.renderFrame` owns those.
    fn submit(self: *SpriteField, engine: *app.Engine) !void {
        const scale: f32 = if (engine.windowInfo()) |i| i.scale else 1;

        try self.renderer.begin(.{ .camera = self.camera, .pixel_scale = scale });

        var it = self.world.queryOf(.{ Transform, Visual });
        while (it.next()) |m| {
            try self.renderer.drawSprite(self.spriteOf(m.get(Transform), m.get(Visual)));
        }

        if (self.selected) |entity| {
            if (self.spriteFor(entity)) |sprite| {
                try self.outline(sprite);
                try self.label(entity, sprite);
            }
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
        if (self.banner_len == 0) return;
        try self.renderer.drawText(self.font, self.banner_buf[0..self.banner_len], .{
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
    fn label(self: *SpriteField, entity: scene.Entity, sprite: render2d.Sprite) !void {
        var buffer: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "#{d}", .{entity.index}) catch return;

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
/// How many sprites to draw: what the content says, unless the environment overrides it.
///
/// Content is the answer and the variable is the override, not the other way round. The
/// variable stays because a scripted run wants to vary the load without editing content,
/// which is the same reason `FOUNDRY_SANDBOX_RESIZE_EVERY` exists.
fn spriteCount(engine: *app.Engine, from_content: u32) u32 {
    const text = engine.os.envVar("FOUNDRY_SANDBOX_SPRITES") orelse return from_content;
    return std.fmt.parseInt(u32, text, 10) catch |err| {
        log.warn("FOUNDRY_SANDBOX_SPRITES='{s}' is not a count ({t}); using {d}", .{ text, err, from_content });
        return from_content;
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
