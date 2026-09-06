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
const audio = @import("audio");
const data = @import("data");
const physics2d = @import("physics2d");
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
    field.walk_every = everyFrames(engine, "FOUNDRY_SANDBOX_WALK");

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
        log.info("WASD walks the player; arrows pan; shift pans faster; drag with right or middle", .{});
        log.info("wheel zooms about the cursor; left-click picks; C follows the player again", .{});
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
        field.audioFrame();
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
            log.debug("frame {d}: {d} sprites ({d} glyphs, {d} tiles), {d} batches, {d} draw calls, {d} KiB of vertices, {d:.1}ms/frame, zoom {d:.2}", .{
                engine.frame_index,
                stats.sprites,
                stats.glyphs,
                // The number `tilemaps-and-collision.md` §10 names as the trigger for ever
                // caching a tilemap. Visible from the day there is one to count.
                stats.tiles,
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
    if (field.save_path) |path| {
        field.reportAnimation("saved");
        field.saveWorld(engine, path);
    }

    // The number that says collision happened rather than compiled. A scripted walk that
    // reports zero contacts has driven through the walls, and the map is 12x10 with a solid
    // border — there is nowhere to walk that does not eventually reach one.
    if (field.player) |entity| {
        const at = field.playerAt() orelse core.math.Vec2.zero;
        // The animation reported the same way and for the same reason: a run nobody
        // watched should say whether the clip actually advanced, and a `frame 0` after
        // three hundred ticks of walking is a system that was registered and never ran.
        const showing = field.animationOf(entity);
        log.info("player finished at ({d:.1}, {d:.1}) with {d} contact(s), on frame {d} of {f} after {d} tick(s)", .{
            at.x,
            at.y,
            field.contacts,
            if (showing) |a| a.frame else 0,
            if (showing) |a| a.clip else core.ContentId.none,
            if (showing) |a| a.elapsed_ticks else 0,
        });
    }

    log.info("clean exit after {d} frames, {d} ticks, {d}ms simulated, {d} sound(s) started", .{
        engine.frame_index,
        engine.stepper.tick,
        engine.elapsed().toMillis(),
        field.sounds_played,
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
    /// The map to draw under the field. `.none` draws no map, which is what a package
    /// without one means and not a reason to stop.
    map: core.ContentId,
    /// The player's box, one side in world units, and how fast it walks in world units
    /// per second.
    ///
    /// **Gameplay numbers come from content; appearance is generated.** The field's 4000
    /// sprites get their size and colour from a seeded generator, and the player is drawn
    /// the same way; what a record owns is the two numbers a person would tune, which is
    /// the line I5 draws.
    player_size: f32,
    player_speed: f32,
    /// Which clip the player plays while moving and while standing still, and which one
    /// the field plays.
    ///
    /// **The choice of clip is content, not only the clip itself.** A package placed after
    /// this one can retime the walk, reskin it onto another sheet, or point the player at
    /// an entirely different animation, and no code here learns that it happened — which
    /// is the whole of what §7 claims sprite animation exposes to Tier 1.
    player_walk: core.ContentId,
    player_idle: core.ContentId,
    field_clip: core.ContentId,
    /// What the sample plays: a tick while walking, a thud on a contact, and a loop that
    /// never stops. Ids, so a package after this one can replace any of them with its own
    /// `.wav` and no code here learns that it happened.
    step_sound: core.ContentId,
    bump_sound: core.ContentId,
    hum_sound: core.ContentId,

    /// Where the record is, and the only content id spelled in this file. Everything else
    /// the sample draws is reached through it.
    const id = "sandbox:settings.main";

    const fallback: Settings = .{
        .sprites = 4000,
        .grid = 4,
        .banner = "",
        .sheet = .none,
        .font = .none,
        .map = .none,
        .player_size = 12,
        .player_speed = 84,
        .player_walk = .none,
        .player_idle = .none,
        .field_clip = .none,
        .step_sound = .none,
        .bump_sound = .none,
        .hum_sound = .none,
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
            .map = idField(record, "map"),
            .player_size = floatField(record, "player_size", fallback.player_size),
            .player_speed = floatField(record, "player_speed", fallback.player_speed),
            .player_walk = idField(record, "player_walk"),
            .player_idle = idField(record, "player_idle"),
            .field_clip = idField(record, "field_clip"),
            .step_sound = idField(record, "step_sound"),
            .bump_sound = idField(record, "bump_sound"),
            .hum_sound = idField(record, "hum_sound"),
        };
    }

    fn intField(record: data.store.Record, name: []const u8, fallback_value: u32) u32 {
        const index = record.schema.fieldIndex(name) orelse return fallback_value;
        const value = (record.fields.intAt(index) catch null) orelse return fallback_value;
        if (value < 0 or value > std.math.maxInt(u32)) return fallback_value;
        return @intCast(value);
    }

    /// A finite, positive number, or the fallback.
    ///
    /// Both callers want a length or a speed, and zero and NaN are neither. `physics2d`
    /// would refuse a degenerate shape anyway — this is the sample answering for its own
    /// content before handing it down, which is what "validated, never asserted" means at
    /// the place the value enters the program.
    fn floatField(record: data.store.Record, name: []const u8, fallback_value: f32) f32 {
        const index = record.schema.fieldIndex(name) orelse return fallback_value;
        const value = (record.fields.floatAt(index) catch null) orelse return fallback_value;
        const narrowed: f32 = @floatCast(value);
        if (!std.math.isFinite(narrowed) or !(narrowed > 0)) return fallback_value;
        return narrowed;
    }

    fn boolField(record: data.store.Record, name: []const u8, fallback_value: bool) bool {
        const index = record.schema.fieldIndex(name) orelse return fallback_value;
        return (record.fields.boolAt(index) catch null) orelse fallback_value;
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

/// The map the sample draws beneath its sprites.
///
/// **This is §11's "the game wires them", written out.** Nothing in the engine turns a
/// `foundry:tilemap` into a drawable or into a collider: `asset` reads the records, the
/// registry answers for the grid and the texture, and this joins them into the
/// `render2d.TilemapLayer` that `drawTilemap` takes **and** the `physics2d.Grid` that
/// `addGrid` takes. One `[]const u16`, borrowed twice, by two modules that cannot see each
/// other — §11's diagram, written out in the only place it can be.
///
/// Which layers collide is content's answer, not this file's: `collides true` on the layer
/// record. A decoration layer over the same grid simply does not say it.
///
/// Every failure here is a log line and a smaller map, never a stopped frame. Content is
/// untrusted, including our own (CLAUDE.md §5), and a sample that refused to start because
/// a mod renamed a tileset would be a bad reference for a game.
const Map = struct {
    /// One drawable plane, holding open the two assets its layer borrows from.
    ///
    /// The `[]const u16` inside `layer` lives in the grid asset's payload and the region
    /// was cut from the texture's, so both handles have to outlive the layer — which is the
    /// same rule as the sheet region, one level up.
    const Plane = struct {
        texture: asset.AssetHandle,
        grid: asset.AssetHandle,
        layer: render2d.TilemapLayer,
        /// The tileset's `solid` list, as the bitset `physics2d.Grid` wants.
        ///
        /// **Owned here, borrowed by the collision world.** `addGrid` copies the descriptor
        /// and not the arrays, so whoever loaded them keeps them alive — which is what lets
        /// `physics2d` stay at L1 without ever learning what an asset is.
        solid: []u32,
        /// The static geometry this layer contributed, or none when it does not collide.
        collision: physics2d.GridHandle,
    };

    planes: std.ArrayList(Plane) = .empty,
    /// Cells, and where cell (0,0)'s corner sits. Enough to say where the middle is, which
    /// is where the sample puts the player.
    width: u32 = 0,
    height: u32 = 0,
    origin: core.math.Vec2 = .zero,
    cell: core.math.Vec2 = .zero,

    /// The middle of the map in world units, or the world origin when there is no map.
    fn center(self: *const Map) core.math.Vec2 {
        if (self.width == 0 or self.height == 0) return .zero;
        return .init(
            self.origin.x + @as(f32, @floatFromInt(self.width)) * self.cell.x / 2,
            self.origin.y + @as(f32, @floatFromInt(self.height)) * self.cell.y / 2,
        );
    }

    /// Reads `id` and everything it names, replacing whatever was here.
    ///
    /// **Where the map goes is the game's decision, not the content's.** `foundry:tilemap`
    /// says how big a map is and how big a cell is; it does not say where the map sits,
    /// because a world holds many maps in many places and one of them being at the origin
    /// is a property of this sample rather than of maps. The sandbox centres it, so the
    /// camera starts looking at it.
    fn build(
        self: *Map,
        gpa: std.mem.Allocator,
        engine: *app.Engine,
        renderer: *render2d.Renderer,
        physics: *physics2d.World,
        id: core.ContentId,
    ) void {
        self.clear(gpa, engine, physics);
        if (id.isNone()) return;

        const record = engine.store.lookup(id) orelse {
            log.warn("no map '{f}' in any loaded package; drawing none", .{id});
            return;
        };
        const map = asset.tilemap.readTilemap(record) catch |err| {
            log.warn("map '{f}' is not a map ({t}); drawing none", .{ id, err });
            return;
        };
        const layers = asset.tilemap.layerIds(gpa, record) catch |err| {
            log.warn("map '{f}' layers could not be read ({t}); drawing none", .{ id, err });
            return;
        };
        defer gpa.free(layers);

        self.width = map.width;
        self.height = map.height;
        self.cell = .init(map.cell_width, map.cell_height);
        self.origin = .init(
            -@as(f32, @floatFromInt(map.width)) * self.cell.x / 2,
            -@as(f32, @floatFromInt(map.height)) * self.cell.y / 2,
        );

        var solid_layers: usize = 0;
        for (layers) |layer_id| {
            const plane = self.readPlane(gpa, engine, renderer, physics, layer_id, map) orelse continue;
            if (!plane.collision.isNone()) solid_layers += 1;
            self.planes.append(gpa, plane) catch {
                _ = physics.removeGrid(plane.collision);
                gpa.free(plane.solid);
                engine.assets.release(plane.texture);
                engine.assets.release(plane.grid);
                log.warn("out of memory building map '{f}'; drawing {d} of its layers", .{ id, self.planes.items.len });
                return;
            };
        }
        log.info("map '{f}': {d}x{d} cells of {d}x{d}, {d} layer(s) drawn, {d} of them solid", .{
            id,          map.width,             map.height,   self.cell.x,
            self.cell.y, self.planes.items.len, solid_layers,
        });
    }

    /// One layer, or null with a reason logged. Acquires nothing it does not return.
    fn readPlane(
        self: *Map,
        gpa: std.mem.Allocator,
        engine: *app.Engine,
        renderer: *render2d.Renderer,
        physics: *physics2d.World,
        layer_id: core.ContentId,
        map: asset.tilemap.Tilemap,
    ) ?Plane {
        const layer_record = engine.store.lookup(layer_id) orelse {
            log.warn("map layer '{f}' is not in any loaded package; skipping it", .{layer_id});
            return null;
        };
        const layer = asset.tilemap.readLayer(layer_record) catch |err| {
            log.warn("map layer '{f}' could not be read ({t}); skipping it", .{ layer_id, err });
            return null;
        };
        const set_record = engine.store.lookup(layer.tileset) orelse {
            log.warn("map layer '{f}' names tileset '{f}', which is not loaded; skipping it", .{ layer_id, layer.tileset });
            return null;
        };
        const set = asset.tilemap.readTileset(set_record) catch |err| {
            log.warn("tileset '{f}' could not be read ({t}); skipping its layer", .{ layer.tileset, err });
            return null;
        };

        // Two acquisitions, and the only two: the art and the numbers. Both are content
        // ids and neither is a path — the sample could not ask for a path if it wanted to
        // (ADR-0021).
        const texture_asset = engine.assets.acquire(gpa, set.texture) catch |err| {
            log.warn("tileset texture '{f}' did not load ({t}); skipping its layer", .{ set.texture, err });
            return null;
        };
        const grid_asset = engine.assets.acquire(gpa, layer.grid) catch |err| {
            log.warn("tile grid '{f}' did not load ({t}); skipping its layer", .{ layer.grid, err });
            engine.assets.release(texture_asset);
            return null;
        };

        var solid: []u32 = &.{};
        var collision: physics2d.GridHandle = .none;
        var ok = false;
        defer if (!ok) {
            _ = physics.removeGrid(collision);
            gpa.free(solid);
            engine.assets.release(grid_asset);
            engine.assets.release(texture_asset);
        };

        const texture_payload = engine.assets.payloadOf(texture_asset) orelse return null;
        const region = renderer.textureRegion(texture_payload.asHandle(render2d.TextureHandle)) orelse {
            log.warn("tileset texture '{f}' is not a texture; skipping its layer", .{set.texture});
            return null;
        };
        const grid_payload = engine.assets.payloadOf(grid_asset) orelse return null;
        const grid = asset.tilegrid.fromPayload(grid_payload);

        // The map says how many cells there are and the grid asset says how many it has.
        // Two files can disagree, and drawing the smaller of the two would quietly hide it.
        if (grid.width != map.width or grid.height != map.height) {
            log.warn("tile grid '{f}' is {d}x{d} but its map is {d}x{d}; skipping the layer", .{
                layer.grid, grid.width, grid.height, map.width, map.height,
            });
            return null;
        }

        // The other consumer of the very same slice. Nothing is copied and nothing is
        // converted: `render2d` is handed `grid.tiles` and so is `physics2d`, and the only
        // thing this code contributes is agreeing about where cell (0,0) is.
        if (layer.collides) {
            solid = asset.tilemap.solidBitset(gpa, set_record) catch |err| {
                log.warn("tileset '{f}' solid list could not be read ({t}); its layer will not collide", .{ layer.tileset, err });
                return null;
            };
            collision = physics.addGrid(gpa, .{
                .origin = self.origin,
                .cell = self.cell,
                .width = grid.width,
                .height = grid.height,
                .tiles = grid.tiles,
                .solid = solid,
            }) catch |err| {
                log.warn("map layer '{f}' could not be collided with ({t}); skipping it", .{ layer_id, err });
                return null;
            };
        }

        ok = true;
        return .{
            .texture = texture_asset,
            .grid = grid_asset,
            .solid = solid,
            .collision = collision,
            .layer = .{
                .tiles = region,
                .tile_size = .{ .width = set.tile_width, .height = set.tile_height },
                .columns = set.columns,
                .map = grid.tiles,
                .width = grid.width,
                .height = grid.height,
                .origin = self.origin,
                .cell = self.cell,
                .empty = layer.empty,
                .layer = layer.order,
            },
        };
    }

    /// Draws every plane, in the order content put them in.
    fn draw(self: *const Map, renderer: *render2d.Renderer) !void {
        for (self.planes.items) |plane| {
            renderer.drawTilemap(plane.layer) catch |err| switch (err) {
                // A layer content made undrawable. Said once at build time is enough; this
                // is the frame path and it keeps drawing the rest.
                error.InvalidTilemap, error.InvalidTexture => {},
                else => return err,
            };
        }
    }

    /// Gives back everything a plane borrowed, in the order it was taken.
    ///
    /// The grid leaves the collision world **before** its arrays are freed, because the
    /// world holds them by reference: a map removed from content and left in the world is a
    /// slice into memory nobody owns any more.
    fn clear(self: *Map, gpa: std.mem.Allocator, engine: *app.Engine, physics: *physics2d.World) void {
        for (self.planes.items) |plane| {
            _ = physics.removeGrid(plane.collision);
            gpa.free(plane.solid);
            engine.assets.release(plane.grid);
            engine.assets.release(plane.texture);
        }
        self.planes.clearRetainingCapacity();
        self.width = 0;
        self.height = 0;
        self.origin = .zero;
        self.cell = .zero;
    }

    fn deinit(self: *Map, gpa: std.mem.Allocator, engine: *app.Engine, physics: *physics2d.World) void {
        self.clear(gpa, engine, physics);
        self.planes.deinit(gpa);
    }
};

/// One animation clip, read out of a `sandbox:clip` record.
///
/// A plain copy rather than a borrowed `Record`, for the reason the banner string is a
/// copy: a content reload frees the package bytes a record reads from, and this outlives a
/// reload by exactly as long as it takes `refresh` to notice. Seven numbers is nothing to
/// copy, and copying is the difference between a rebuild and a use-after-free.
const Clip = struct {
    id: core.ContentId,
    columns: u32,
    rows: u32,
    first: u32,
    count: u32,
    hold: u32,
    loops: bool,

    /// How long one pass takes, widened because `hold * count` comes from a file.
    fn duration(self: *const Clip) u64 {
        return @as(u64, self.hold) * @as(u64, self.count);
    }
};

/// Every clip the loaded packages define, resolved once per content generation.
///
/// **Built by iterating the store rather than by naming the clips the sample uses**, so a
/// component carrying an id from a save, or from a package that arrived after this build,
/// still resolves. A mod adding `sandbox:clip.sprint` gets a clip that works the moment
/// something references it.
///
/// The lookup is a linear scan, and that is honest for three clips rather than a decision
/// worth defending: a real game's table is a map keyed by id, and swapping this for one
/// changes nothing above it.
const Clips = struct {
    list: std.ArrayList(Clip) = .empty,

    /// The sample's own schema, in its own package's namespace. A bare `clip` in a package
    /// named `sandbox:content` is the schema `sandbox:clip` (`content-schemas.md` §4).
    const schema_name = "sandbox:clip";

    fn build(self: *Clips, gpa: std.mem.Allocator, engine: *app.Engine) void {
        self.list.clearRetainingCapacity();

        const schema_id = data.SchemaId.parse(schema_name) catch {
            log.err("'{s}' is not a valid schema id; nothing will animate", .{schema_name});
            return;
        };

        // The store's iteration order is documented and stable (`content-schemas.md` §6),
        // which is what lets the field below pick a clip by index and get the same field
        // twice (I9).
        var it = engine.store.iterate(schema_id);
        while (it.next()) |record| {
            const clip: Clip = .{
                .id = record.id,
                // Clamped at read time rather than at draw time. `Region.cell` answers a
                // zero grid with an empty region, which is right for an index past the
                // last cell — that is a clip running off its sheet and it should show —
                // but a `columns 0` would make every frame of the clip invisible, which
                // says nothing about which number is wrong.
                .columns = @max(Settings.intField(record, "columns", 1), 1),
                .rows = @max(Settings.intField(record, "rows", 1), 1),
                .first = Settings.intField(record, "first", 0),
                .count = Settings.intField(record, "count", 1),
                .hold = Settings.intField(record, "hold", 6),
                .loops = Settings.boolField(record, "loops", true),
            };
            self.list.append(gpa, clip) catch |err| {
                log.warn("could not hold clip {f} ({t}); stopping at {d}", .{ record.id, err, self.list.items.len });
                return;
            };
        }
        log.info("{d} clip(s) loaded", .{self.list.items.len});
    }

    fn find(self: *const Clips, id: core.ContentId) ?*const Clip {
        if (id.isNone()) return null;
        for (self.list.items) |*clip| if (clip.id.eql(id)) return clip;
        return null;
    }

    fn deinit(self: *Clips, gpa: std.mem.Allocator) void {
        self.list.deinit(gpa);
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

/// A box that collides, centred on the entity's transform.
///
/// **The engine defines no `foundry:collider`, deliberately** — M5 adds no engine-owned
/// component types at all (`tilemaps-and-collision.md` §11). A component name is a
/// compatibility decision (`CLAUDE.md` §7), M7 is when the mod-facing vocabulary is chosen,
/// and inventing the standard collider before one game has said what belongs on it would
/// freeze a guess. So the sample defines its own, exactly as it defines `sandbox:transform`.
///
/// It holds half-extents and **not** a `physics2d.BodyHandle`: a handle is a runtime
/// identity that a save must never carry (I1), so what persists is the shape and the body
/// is rebuilt from it on load.
const Collider = struct {
    pub const component = "sandbox:collider";
    half_x: f32 = 6,
    half_y: f32 = 6,
};

/// Where an entity is in a clip.
///
/// **All three fields are integers, and that is the whole design** (`sprite-animation.md`
/// §4). A float accumulator drifts, so two things started together fall visibly out of
/// step; it does not survive a save, reloading to a value that is nearly the same and
/// selecting a frame that is sometimes not; and it makes "which frame at tick 700?" only
/// *nearly* answerable, which is I9's promise broken in the way that is right in nineteen
/// tests out of twenty. `elapsed_ticks` is exact, `frame` is a pure function of it, and
/// the reload check in `main` is what holds this claim rather than this comment.
///
/// `elapsed_ticks` rather than a start tick, because pausing and restarting are then
/// ordinary arithmetic instead of fixups, and because four bytes beats eight in a save.
const Animation = struct {
    pub const component = "sandbox:animation";
    /// The clip being played, **by content id and never by a handle or an index** — this
    /// is serialized, and a runtime identity in a save file is what I1 and ADR-0021 refuse
    /// (`entity-storage.md` §8). It is also what makes a mod's new clip playable by a save
    /// written before that mod existed.
    clip: core.ContentId = .none,
    elapsed_ticks: u32 = 0,
    /// Which frame of the clip is showing, written by the system and read by the draw
    /// code. Clip-relative, so the sheet cell is `clip.first + frame`.
    ///
    /// Cached so drawing does not repeat the arithmetic for an entity that did not tick —
    /// and **not** a `render2d.Region`, because a `Region` carries a `TextureHandle` and
    /// this is serialized. The same rule as the clip id, reached by the same argument.
    frame: u32 = 0,
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

/// Advances every animated entity by one tick and records which frame that lands on.
///
/// **This one is a `scene` system where `walk` could not be**, and the difference is the
/// whole of `entity-storage.md` §7: a system is handed the tick and the delta and nothing
/// else, so it cannot read a device — and advancing a clip does not want to. Driving a
/// character does, which is why that is the game's own function and this is not.
///
/// It reaches `render2d` for the arithmetic, and that is not a layering violation nor even
/// a crossing: `frameAt` is four integers in and one out, `scene` never sees it, and the
/// *game* is what joins the two (`sprite-animation.md` §6). Both modules are L3 and the
/// build graph would refuse the import in either direction.
///
/// Its context is the clip table, resolved once per content generation. Nothing here reads
/// the store: content is resolved by the game, on the frame content changed, and handed to
/// the simulation as plain numbers.
fn animationSystem(ctx: ?*anyopaque, world: *scene.World, tick: scene.Tick) void {
    _ = tick;
    const clips: *const Clips = @ptrCast(@alignCast(ctx orelse return));

    var it = world.queryOf(.{Animation});
    while (it.next()) |m| {
        const animation = m.get(Animation);
        // A clip that is not loaded holds its frame rather than resetting it. Content is
        // untrusted, including our own: a package can be edited between one tick and the
        // next, and the sprite that was mid-walk should not blink to frame zero and back.
        const clip = clips.find(animation.clip) orelse continue;

        // A looping clip wraps its own elapsed count, which keeps the number small in a
        // save and means it can run for as long as anybody leaves it running. A one-shot
        // saturates instead, because wrapping it would replay it.
        const total = clip.duration();
        animation.elapsed_ticks = if (clip.loops and total > 0)
            @intCast((@as(u64, animation.elapsed_ticks) + 1) % total)
        else
            animation.elapsed_ticks +| 1;

        animation.frame = render2d.frameAt(
            animation.elapsed_ticks,
            clip.hold,
            clip.count,
            clip.loops,
        );
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
    font: render2d.BitmapFont,

    /// The map, rebuilt whenever content changes. Empty when the settings record names
    /// none, which is a package without a map rather than a failure.
    map: Map = .{},

    /// Every clip the packages define, rebuilt with the map and for the same reason.
    ///
    /// The animation system holds a pointer to this, which is why it lives here rather
    /// than being passed down: a system's context is set at registration and the table has
    /// to outlive every tick that reads it. Its *contents* are replaced on a reload; its
    /// address is not.
    clips: Clips = .{},

    /// **The collision world is the game's, not the engine's.**
    ///
    /// `app` does not own one and is not going to: `physics2d` has no time in it and
    /// integrates nothing (`tilemaps-and-collision.md` §2), so *when* to move a body and
    /// what to do about what it hit is gameplay, and an engine that owned that would be an
    /// engine you fight. The sample runs it inside its own fixed step.
    physics: physics2d.World = .empty,
    /// The driven body. Held here rather than on the entity, because a body handle is
    /// runtime identity and a save carries none (I1) — `adoptPlayer` rebuilds it.
    player_body: physics2d.BodyHandle = .none,
    /// The entity that body belongs to, found by asking the world who has a collider.
    player: ?scene.Entity = null,
    /// Whether the camera is chasing the player. Any manual pan drops it; `C` picks it
    /// back up. Two ways to move a view is one too many unless one of them yields.
    follow: bool = true,
    /// Ticks per leg of a scripted square walk, or null to be driven by the keyboard.
    ///
    /// Same rationale as `FOUNDRY_SANDBOX_PICK_EVERY`: collision that can only be exercised
    /// by a person holding a key is collision that is checked when somebody remembers to.
    walk_every: ?u64 = null,
    /// Contacts the player has accumulated, so a headless run reports a number that says
    /// whether it ever actually hit anything.
    contacts: u64 = 0,

    /// The mixer, and the one voice the sample keeps a handle to.
    ///
    /// **Optional, because a machine with no output device is a configuration rather than
    /// a failure** (`audio.md` §9). A sample that refused to start on a build machine with
    /// no sound card would be a bad reference for a game.
    mixer: ?*audio.Mixer = null,
    /// The ambience, panned by where the player is. `.none` when the package names no
    /// hum, which is a package without one rather than a failure.
    hum: audio.VoiceHandle = .none,
    /// Ticks since the last footstep. **Simulation state, so it counts ticks and not
    /// seconds** (I9) — and it is a cause of sound, never a reading of one.
    since_step: u64 = 0,
    /// Sounds started, so a headless run reports a number that says whether the sample
    /// ever asked for one. It cannot report what was *heard*: nothing above the device
    /// may observe where a sound got to (`audio.md` §8).
    sounds_played: u64 = 0,

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
    collider: scene.ComponentType = .none,
    animation: scene.ComponentType = .none,
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

    /// Ticks between footsteps while walking. At 60 Hz this is a step every third of a
    /// second, which is a walk rather than a sprint.
    const step_interval: u64 = 20;

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

        // The mixer opens the device and registers its own loader the same way, for the
        // same reason: `app` has neither `render2d` nor `audio`, so both capabilities are
        // handed up from the game (I6). It is also why the engine gains no dependency on
        // a mixer it does not own.
        self.mixer = audio.Mixer.init(gpa, engine.platform, &engine.assets, .{}) catch |err| blk: {
            // Reported and carried on, because a machine with no output device is a
            // configuration and not a bug (`audio.md` §9).
            log.warn("no audio device ({t}); the sandbox runs silent", .{err});
            break :blk null;
        };
        if (self.mixer) |mixer| try engine.assets.registerLoader(gpa, mixer.soundLoader());

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
        self.map.build(gpa, engine, &self.renderer, &self.physics, self.settings.map);
        self.clips.build(gpa, engine);
        self.content_generation = engine.contentGeneration();

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

        // Either path leaves an entity with a collider in the world; this is what gives it
        // a body. A restored save brought the entity back and nothing else, which is the
        // whole reason the two are separate calls.
        self.adoptPlayer();
        if (restored) self.reportAnimation("resumed");

        // Last, because it wants the settings the record named and the map the player
        // stands in the middle of.
        self.startHum();
    }

    /// Starts the looping ambience, or leaves the sample quiet.
    ///
    /// Nothing here is a reason to stop: no mixer, no hum in the package, or no free voice
    /// each mean one fewer sound, and a sample that refused to run over any of them would
    /// be a bad reference.
    fn startHum(self: *SpriteField) void {
        const mixer = self.mixer orelse return;
        if (self.settings.hum_sound.isNone()) return;

        self.hum = mixer.play(self.settings.hum_sound, .{ .looping = true, .gain = 0.4 }) catch |err| {
            log.warn("the ambience did not start ({t})", .{err});
            return;
        };
        self.sounds_played += 1;
    }

    /// Starts a one-shot, or does nothing.
    ///
    /// **A sound that could not play is not a failure**: `play` refusing when every voice
    /// is busy is the design working — the mixer steals nothing and the game decides
    /// (`audio.md` §11) — and what this sample decides is that a footstep it could not
    /// afford is a footstep nobody misses.
    fn emit(self: *SpriteField, id: core.ContentId, params: audio.PlayParams) void {
        // **A headless build has a device that never runs**, so a command queued here
        // would sit in the ring until it filled and every one after it was refused. That
        // is the mixer behaving correctly and the sample asking for something pointless;
        // not asking is the honest version. The ambience still starts, so a headless run
        // still decodes a `.wav` through the real path.
        if (platform.backend == .null) return;
        const mixer = self.mixer orelse return;
        if (id.isNone()) return;
        _ = mixer.play(id, params) catch |err| {
            // Debug, because a footstep losing a race for the last voice would otherwise
            // write sixty log lines a second.
            log.debug("sound {f} did not play: {t}", .{ id, err });
            return;
        };
        self.sounds_played += 1;
    }

    /// The mixer's frame: retire what finished, and put the ambience where the player is.
    ///
    /// **Not in the fixed step, and that is structural.** Where a sound is panned is
    /// presentation, derived from where the player is drawn; `update` is a once-per-frame
    /// call by definition (`audio.md` §7); and nothing in a simulation may read a mixer at
    /// all — `scene` cannot see `audio`, so nothing here could be a system even if someone
    /// wanted it to be (§8).
    fn audioFrame(self: *SpriteField) void {
        const mixer = self.mixer orelse return;
        // Retirements come back here and nowhere else. Skip it and voices never return to
        // the free list, which is a loud failure the moment the pool runs out rather than
        // a slow leak — the right way round.
        mixer.update();

        if (self.hum.isNone() or !mixer.isPlaying(self.hum)) return;
        const at = self.playerAt() orelse return;

        // The ambience sits at the middle of the map, so walking left moves it right.
        // Half the map's width is the whole pan range; the mixer clamps the rest.
        const centre = self.map.center();
        const span = @max(1.0, @as(f32, @floatFromInt(self.map.width)) * self.map.cell.x * 0.5);
        mixer.setPan(self.hum, (centre.x - at.x) / span);
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
        self.collider = try self.world.registerComponent(scene.componentType(Collider));
        self.animation = try self.world.registerComponent(scene.componentType(Animation));
        _ = try self.world.registerSystem(.{
            .id = try data.contentId("sandbox:system.orbit"),
            .name = "sandbox:system.orbit",
            .update = &orbitSystem,
        });
        // Registered after the orbit, which is also the order they run in. Nothing here
        // depends on that — one writes a transform and the other a frame index — but the
        // order is a property of the registration rather than of the data, which is what
        // `entity-storage.md` §7 asks systems to be.
        _ = try self.world.registerSystem(.{
            .id = try data.contentId("sandbox:system.animation"),
            .name = "sandbox:system.animation",
            .ctx = &self.clips,
            .update = &animationSystem,
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
        // The entity is gone with the world it lived in. Its body outlives it for a moment
        // and is reclaimed by `adoptPlayer`, which every caller of this reaches next.
        self.player = null;
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

    /// What the player is showing, for the log line either side of a save.
    ///
    /// **`sprite-animation.md` §10 step 3's check, at the sample's scale.** The suite holds
    /// the claim properly — `engine/tests/sprite_animation.zig` compares the actual UVs
    /// across a reload and then runs both worlds four hundred ticks further — and this is
    /// the same fact where a person can see it: run once with a save path, run again with a
    /// load path, and the two lines say the same clip, the same elapsed count and the same
    /// frame.
    fn reportAnimation(self: *SpriteField, what: []const u8) void {
        const entity = self.player orelse return;
        const animation = self.animationOf(entity) orelse return;
        log.info("player {s} on frame {d} of {f}, {d} tick(s) in", .{
            what,
            animation.frame,
            animation.clip,
            animation.elapsed_ticks,
        });
    }

    /// One fixed simulation step. The game translates `app`'s step into `scene`'s tick.
    ///
    /// The two are deliberately different types. `app.Step` carries the frame's input
    /// snapshot and the elapsed total; a system is entitled to the tick number and the fixed
    /// delta and nothing else, which is what makes a simulation reproducible and what stops
    /// it reading a device (`entity-storage.md` §7).
    fn step(self: *SpriteField, s: app.Step) void {
        self.world.update(.{ .tick = s.tick, .delta = s.delta });
        self.walk(s);
    }

    /// Moves the player, in the fixed step, against the map.
    ///
    /// **This is not a `scene` system, and it cannot be.** A system is handed the tick and
    /// the delta and nothing else, precisely so a simulation cannot read a device
    /// (`entity-storage.md` §7) — and driving something is reading a device. So it is the
    /// game's code, running in the game's fixed step, reading the step's frozen input
    /// snapshot rather than the live one (I9).
    ///
    /// The whole of the collision call is three lines in the middle: a vector in, a
    /// position and a list of contacts out. There is no velocity, no acceleration and no
    /// `dt` anywhere below this function, which is what ADR-0022's "collision, not
    /// dynamics" buys — how it feels to walk stays here, where it can be tuned.
    fn walk(self: *SpriteField, s: app.Step) void {
        const entity = self.player orelse return;

        var direction: core.math.Vec2 = .zero;
        if (self.walk_every) |legs| {
            // A square circuit, a pure function of the tick, so a run nobody is watching
            // still drives the player into walls — and into the same walls every time.
            direction = switch ((s.tick / legs) % 4) {
                0 => .init(1, 0),
                1 => .init(0, 1),
                2 => .init(-1, 0),
                else => .init(0, -1),
            };
        } else {
            const in = &s.input;
            // World space, so `w` is **+y**. The camera's pan two functions down uses the
            // opposite sign for the same key, because it moves in screen space, which is
            // Y-down. The two disagreeing is correct and is worth saying out loud.
            if (in.isHeld(.a)) direction.x -= 1;
            if (in.isHeld(.d)) direction.x += 1;
            if (in.isHeld(.w)) direction.y += 1;
            if (in.isHeld(.s)) direction.y -= 1;
        }
        // Which clip plays is the game's decision, made every tick from what the game
        // already knows. That is the whole of `sprite-animation.md` §8's "transitions are
        // game policy built on this" at the sample's scale: one comparison, no state
        // machine, and nothing in the engine that had to be told about walking.
        const standing = direction.eql(.zero);
        self.play(entity, if (standing) self.settings.player_idle else self.settings.player_walk);
        if (standing) {
            // Primed, so the first step after standing still lands on the tick the player
            // starts moving rather than a third of a second into it.
            self.since_step = step_interval;
            return;
        }

        // **The simulation may cause a sound and may never observe one** (`audio.md` §8).
        // This is the causing half: a count of ticks, in the fixed step, deciding to emit.
        // Nothing below reads back where any sound has got to, and nothing could.
        self.since_step += 1;
        if (self.since_step >= step_interval) {
            self.since_step = 0;
            self.emit(self.settings.step_sound, .{ .gain = 0.5 });
        }

        const motion = direction.normalize().scale(self.settings.player_speed * s.delta.toSecondsF32());
        var hits: [4]physics2d.Hit = undefined;
        const result = (self.physics.moveAndSlide(self.gpa, self.player_body, motion, &hits) catch |err| {
            log.warn("the player could not move: {t}", .{err});
            return;
        }) orelse return;

        if (result.total_hits > 0) self.emit(self.settings.bump_sound, .{ .gain = 0.55 });
        self.contacts += result.total_hits;
        self.writeBack(entity, result.position);
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
        // Rebuilt rather than patched. Everything in a plane is *derived* — a region cut
        // from a texture, a slice into a grid's payload — and a reload is exactly the event
        // that invalidates derived things (`assets.md` §6).
        self.map.build(self.gpa, engine, &self.renderer, &self.physics, self.settings.map);
        // Rebuilt for the map's reason: a `Clip` is a copy of numbers a package owns, and
        // a reload frees the bytes they were read from. Entities keep their `clip` ids and
        // their elapsed counts across it, so retiming a clip in a file changes the speed of
        // an animation that is already playing without restarting it.
        self.clips.build(self.gpa, engine);
        // A package placed after this one can point the ambience at a different `.wav`.
        // Only a *different id* restarts it: a hum whose bytes changed keeps its handle
        // and its position, which is the whole point of the reload rule holding one layer
        // down (`assets.md` §6).
        if (!self.settings.hum_sound.eql(previous.hum_sound)) {
            if (self.mixer) |mixer| mixer.stop(self.hum);
            self.hum = .none;
            self.startHum();
        }
        // The map that just replaced the old one may have put a wall where the player was
        // standing. A sweep cannot undo that — the time of impact is behind it — so this is
        // the call that can (`tilemaps-and-collision.md` §6).
        self.settlePlayer();

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
                // `populate` destroyed and remade the player along with everything else.
                self.adoptPlayer();
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

            // **The phase is per-entity state; the clip is not.** Four thousand sprites
            // share one `sandbox:clip.drift` record and each starts somewhere else in it,
            // which is exactly the split the component exists to express — and the reason
            // `elapsed_ticks` is on the entity rather than the clip being duplicated.
            //
            // From the same seeded generator as everything else above, so the field looks
            // identical on every run (I9).
            var animation: Animation = .{ .clip = self.settings.field_clip };
            if (self.clips.find(self.settings.field_clip)) |clip| {
                const total = clip.duration();
                if (total > 0) animation.elapsed_ticks = @intCast(rng.below(@intCast(@min(total, std.math.maxInt(u32)))));
            }

            _ = try self.world.addComponent(entity, self.orbit, std.mem.asBytes(&orbit));
            _ = try self.world.addComponent(entity, self.visual, std.mem.asBytes(&visual));
            _ = try self.world.addComponent(entity, self.animation, std.mem.asBytes(&animation));
            // Zeroed until the first tick runs the system. The order the components are
            // added in is the order the stores hold them, and drawing iterates the
            // transform store, so this is also the draw order.
            _ = try self.world.addComponent(entity, self.transform, null);
        }
        self.population = count;

        // One step's worth, so the field has positions before the first frame draws it
        // rather than a frame of everything at the origin.
        self.world.update(.{ .tick = 0, .delta = .fromMillis(0) });

        // And the one entity a person drives. Created last so the field's rebuild cannot
        // destroy it; given a body by `adoptPlayer`, which every caller of this reaches.
        try self.spawnPlayer();
    }

    /// Creates the driven entity in the middle of the map.
    ///
    /// Three ordinary components and no special case: it is a `Transform` and a `Visual`
    /// like the other four thousand, plus a `Collider`, and *having a collider* is the
    /// whole of what makes it the player. Its appearance is chosen here because every
    /// sprite's appearance is chosen here; its size and speed come from content, because
    /// those are the numbers somebody would tune.
    fn spawnPlayer(self: *SpriteField) !void {
        const half = self.settings.player_size / 2;
        const at = self.map.center();

        var collider: Collider = .{ .half_x = half, .half_y = half };
        var transform: Transform = .{ .x = at.x, .y = at.y };
        var visual: Visual = .{
            .size = self.settings.player_size,
            .cell = 0,
            .tint = .srgb8(255, 240, 170, 255),
            // Above the field's three layers and its additive fourth, so the thing being
            // driven is never lost behind the thing being stress-tested.
            .layer = 5,
        };

        // Standing still until something drives it. Which clip plays is `walk`'s decision
        // every tick, and a still pose is a clip like any other rather than a fifth state
        // for the absence of one.
        var animation: Animation = .{ .clip = self.settings.player_idle };

        const entity = try self.world.create();
        _ = try self.world.addComponent(entity, self.collider, std.mem.asBytes(&collider));
        _ = try self.world.addComponent(entity, self.visual, std.mem.asBytes(&visual));
        _ = try self.world.addComponent(entity, self.animation, std.mem.asBytes(&animation));
        _ = try self.world.addComponent(entity, self.transform, std.mem.asBytes(&transform));
    }

    /// Finds whoever has a collider and gives them a body in the collision world.
    ///
    /// **Separate from spawning because a save brings the entity back and not the body.**
    /// A `BodyHandle` is runtime identity, which I1 forbids serializing, so the durable
    /// record of "this thing collides" is the `Collider` component and the body is derived
    /// from it — on a fresh spawn, on a load, and on a repopulate alike.
    ///
    /// Nothing here can fail the frame. A sample with no body walks through walls and says
    /// so, which is a worse sample and not a stopped one.
    fn adoptPlayer(self: *SpriteField) void {
        if (!self.player_body.isNone()) {
            _ = self.physics.removeBody(self.gpa, self.player_body);
            self.player_body = .none;
        }
        self.player = null;

        // A world can arrive without one: a save written before this sample had a player
        // loads perfectly well and simply has nothing to drive. Making one is friendlier
        // than refusing, and it is the same call a fresh world takes.
        var probe = self.world.queryOf(.{ Collider, Transform });
        if (probe.next() == null) {
            log.info("nothing in the world has a collider; spawning a player", .{});
            self.spawnPlayer() catch |err| {
                log.warn("could not spawn a player ({t}); there is nobody to drive", .{err});
                return;
            };
        }

        var it = self.world.queryOf(.{ Collider, Transform });
        const found = it.next() orelse return;
        const collider = found.get(Collider);
        const transform = found.get(Transform);

        self.player_body = self.physics.addBody(self.gpa, .{
            .shape = .{ .box = .init(collider.half_x, collider.half_y) },
            .position = .init(transform.x, transform.y),
            .kind = .movable,
            // The entire coupling between `physics2d` and the rest of the engine: an opaque
            // `u64` the module never interprets, holding the entity this body is
            // (`tilemaps-and-collision.md` §2). It is how a contact names something.
            .user = found.entity.bits(),
        }) catch |err| {
            log.warn("the player could not be given a body ({t}); it will walk through walls", .{err});
            return;
        };
        self.player = found.entity;
        self.settlePlayer();
    }

    /// Pushes the player out of anything it is standing inside, and moves the entity with it.
    ///
    /// The other half of §6, and deliberately not part of moving: a body that *starts*
    /// overlapping is not something a sweep can fix, so "I am stuck in a wall" stays a
    /// state the game is told about rather than a teleport it never sees. The moment it
    /// matters is a content reload that turns the floor underfoot into a wall.
    fn settlePlayer(self: *SpriteField) void {
        const entity = self.player orelse return;
        var hits: [4]physics2d.Hit = undefined;
        const result = (self.physics.resolveOverlaps(self.gpa, self.player_body, &hits) catch |err| {
            log.warn("the player could not be settled: {t}", .{err});
            return;
        }) orelse return;

        self.writeBack(entity, result.position);
        if (result.started_inside) {
            log.info("the player was inside {d} solid thing(s); pushed out to ({d:.1}, {d:.1})", .{
                result.total_hits, result.position.x, result.position.y,
            });
        }
    }

    /// Copies a body's position onto its entity's transform.
    ///
    /// One direction only, and that is the arrangement rather than a shortcut: the body is
    /// authoritative while it is being moved, and the transform is what everything else —
    /// drawing, picking, saving — reads. A second writer would be two truths.
    /// Points an entity at a clip, restarting it only when it is a different one.
    ///
    /// The "only when different" is what makes this callable every tick: a walk that reset
    /// its elapsed count on every frame it was still walking would hold frame zero forever
    /// and look like an animation that does not play.
    fn play(self: *SpriteField, entity: scene.Entity, clip: core.ContentId) void {
        const found = self.world.getComponent(entity, self.animation) orelse return;
        const animation: *Animation = @ptrCast(@alignCast(found.ptr));
        if (animation.clip.eql(clip)) return;
        animation.clip = clip;
        animation.elapsed_ticks = 0;
        animation.frame = 0;
    }

    fn writeBack(self: *SpriteField, entity: scene.Entity, at: core.math.Vec2) void {
        const bytes = self.world.getComponent(entity, self.transform) orelse return;
        const transform: *Transform = @ptrCast(@alignCast(bytes.ptr));
        transform.x = at.x;
        transform.y = at.y;
    }

    /// Where the player is, for the camera and the readout.
    fn playerAt(self: *SpriteField) ?core.math.Vec2 {
        const body = self.physics.body(self.player_body) orelse return null;
        return body.position;
    }

    /// **The asset loader goes back before the renderer does.**
    ///
    /// `unregisterLoader` hands every texture this renderer made back to it while it still
    /// exists. Without it the engine's registry would unload through a `*Renderer` that had
    /// already been torn down — a teardown-order bug the compiler cannot see, and the
    /// reason that call exists.
    fn deinit(self: *SpriteField, engine: *app.Engine) void {
        // Before the collision world, because a plane's grid is registered in it and the
        // arrays that grid borrows are the plane's to free.
        self.map.deinit(self.gpa, engine, &self.physics);
        self.physics.deinit(self.gpa);
        // After the world, in effect: the system holding a pointer to this stops running
        // when `world.deinit` below runs, and nothing between here and there ticks.
        self.clips.deinit(self.gpa);
        engine.assets.release(self.sheet_asset);
        engine.assets.release(self.font_asset);
        _ = engine.assets.unregisterLoader(self.gpa, asset.schemas.texture.id);
        // The same shape as the texture loader above, with one extra step in the middle.
        // `shutdown` closes the device and hands back the asset reference every playing
        // voice held; only then may the loader go, or the registry would rightly report
        // that the ambience is still holding the sound it is unloading.
        if (self.mixer) |mixer| {
            mixer.shutdown();
            _ = engine.assets.unregisterLoader(self.gpa, asset.schemas.sound.id);
            mixer.deinit();
            self.mixer = null;
        }

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
    fn spriteOf(
        self: *const SpriteField,
        transform: *const Transform,
        visual: *const Visual,
        animation: ?*const Animation,
    ) render2d.Sprite {
        const cell = self.cellOf(visual, animation);

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

    /// Which piece of the sheet an entity is showing.
    ///
    /// **This is `sprite-animation.md` §6's join, and it is three lines.** The entity side
    /// knows a clip id and a frame number and has never heard of a texture; the renderer
    /// side turns a grid position into a region and has never heard of an entity; the game
    /// is where they meet, in the same function that already turned a transform and a
    /// visual into a sprite. Neither module gained a dependency, and the layering would
    /// have refused one in either direction — both are L3 (I7).
    ///
    /// `Region.cell` cuts in the *sheet's* pixel space rather than the atlas's, which is
    /// why none of this changes if the sheet is packed into something larger later.
    ///
    /// An entity with no animation, or one naming a clip no package defines, falls back to
    /// the cell its `Visual` was authored with. That is what keeps the four thousand
    /// drawable while a mid-run content edit is halfway through replacing their clip.
    fn cellOf(self: *const SpriteField, visual: *const Visual, animation: ?*const Animation) render2d.Region {
        if (animation) |current| {
            if (self.clips.find(current.clip)) |clip| {
                // Saturating: a clip whose `first + count` runs past its sheet is a content
                // mistake, and `Region.cell` answers an out-of-range index with an empty
                // region rather than with a neighbouring sprite's pixels.
                return self.sheet.cell(clip.columns, clip.rows, clip.first +| current.frame);
            }
        }
        const grid = @max(self.settings.grid, 1);
        return self.sheet.cell(grid, grid, visual.cell);
    }

    /// The animation on an entity, or null when it has none.
    fn animationOf(self: *SpriteField, entity: scene.Entity) ?*const Animation {
        const found = self.world.getComponent(entity, self.animation) orelse return null;
        return @ptrCast(@alignCast(found.ptr));
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
            self.animationOf(entity),
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
            self.follow = true;
            self.camera.center = self.playerAt() orelse .zero;
            self.camera.zoom = 1;
            self.selected = null;
            log.info("camera recentred, and following the player again", .{});
        }

        // The whole world to a file and back, through the same path a scripted run uses.
        if (self.save_path) |path| {
            if (in.wasPressed(.f5)) self.saveWorld(engine, path);
            if (in.wasPressed(.f9)) {
                if (!self.loadWorld(engine, path)) {
                    self.populate(spriteCount(engine, self.settings.sprites)) catch |err| {
                        log.warn("could not rebuild the field: {t}", .{err});
                    };
                }
                // Either way the world is a new one, and the body that was pointing into
                // the old one has to be made again.
                self.adoptPlayer();
                self.reportAnimation("resumed");
            }
        }

        // Screen-space pan, on the **arrows**. WASD used to do this too and now drives the
        // player: two things cannot answer to the same key, and once there is something to
        // drive, driving it is what those four keys mean in a top-down game.
        //
        // Up moves the view up, which is *negative* screen Y, because screen space is
        // Y-down and `panByScreen` speaks screen space. `walk` uses the opposite sign for
        // the same intent, in world space, and that is not a mistake in either.
        var direction: core.math.Vec2 = .zero;
        if (in.isHeld(.left)) direction.x -= 1;
        if (in.isHeld(.right)) direction.x += 1;
        if (in.isHeld(.up)) direction.y -= 1;
        if (in.isHeld(.down)) direction.y += 1;
        if (!direction.eql(.zero)) {
            const speed = if (in.modifiers.shift) fast_pan_speed else pan_speed;
            self.pan(direction.normalize().scale(speed * dt));
            self.follow = false;
        }

        // Drag to pan. The negation is the difference between moving the camera and
        // moving the content: dragging right should bring what is on the left into view.
        if (in.mouse.isHeld(.right) or in.mouse.isHeld(.middle)) {
            if (!in.mouse.motion.eql(.zero)) self.follow = false;
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

        // The camera follows what is being driven, unless something above said not to.
        // Applied here rather than when the player moves, because where a camera looks is
        // presentation and belongs outside the fixed step — and because it must land after
        // the zoom, which reads the centre it is zooming about.
        if (self.follow) {
            if (self.playerAt()) |at| self.camera.center = at;
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
            // The same sprite `submit` drew, animation and all: picking has to hit-test
            // what is on screen, and an animated sprite's cell is what is on screen.
            const sprite = self.spriteOf(m.get(Transform), m.get(Visual), self.animationOf(m.entity));
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

        // The ground, before anything standing on it. Which is *under* which is the sort
        // layer's business — the map's layers carry their own `order` from content — and
        // submitting first only settles ties.
        try self.map.draw(&self.renderer);

        var it = self.world.queryOf(.{ Transform, Visual });
        while (it.next()) |m| {
            // Asked for per entity rather than named in the query, because an animation is
            // **optional**: a query naming it would silently stop drawing anything that
            // does not have one, which for a sample that spawns un-animated entities is a
            // regression that looks like a content bug.
            try self.renderer.drawSprite(self.spriteOf(m.get(Transform), m.get(Visual), self.animationOf(m.entity)));
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
        const at = self.playerAt() orelse core.math.Vec2.zero;

        var buffer: [512]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            "{d:.1}ms  {d} sprites  {d} glyphs  {d} tiles\n" ++
                "{d} batches  {d} draw calls  {d} views\n" ++
                "{d} KiB vertices  {d} buffers  zoom {d:.2}\n" ++
                "player ({d:.0}, {d:.0})  {d} contacts  frame {d}{s}",
            .{
                engine.frameDelta().toSecondsF32() * 1000,
                stats.sprites,
                stats.glyphs,
                stats.tiles,
                stats.batches,
                stats.draw_calls,
                stats.views,
                stats.vertex_bytes / 1024,
                stats.buffers_used,
                self.camera.zoom,
                at.x,
                at.y,
                self.contacts,
                if (self.player) |e| (if (self.animationOf(e)) |a| a.frame else 0) else 0,
                if (self.follow) "  following" else "",
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

        // A panel behind it, so the readout is legible over whatever it lands on, from
        // the renderer's own white patch rather than from a texture this sample builds.
        const blank = self.renderer.blankRegion();
        try self.renderer.drawSprite(.{
            .texture = blank.texture,
            .uv = blank.uv,
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
        const help = "wasd walks  arrows pan  wheel zoom  click picks  c follows";
        const help_options: render2d.TextOptions = .{ .position = .zero, .scale = 1.5 };
        const help_size = render2d.measureText(self.font, help, help_options);
        const help_at: core.math.Vec2 = .init(
            width - help_size.x - hud_margin - hud_padding,
            hud_margin + hud_padding,
        );
        try self.renderer.drawSprite(.{
            .texture = blank.texture,
            .uv = blank.uv,
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

        const blank = self.renderer.blankRegion();
        for (edges) |edge| {
            try self.renderer.drawSprite(.{
                .texture = blank.texture,
                .uv = blank.uv,
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
/// picks at the window centre, taking exactly the path a click takes;
/// `FOUNDRY_SANDBOX_WALK` gives the player a leg length in **ticks** and walks it in a
/// square, which is how a headless run collides with anything at all.
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
