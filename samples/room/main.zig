//! `samples/room` — the smallest thing that is a game rather than a demonstration of one.
//!
//! **Why there are two samples.** `samples/sandbox` demonstrates capabilities: four
//! thousand sprites, a frame-statistics readout, entity picking, world save and load,
//! window resizing on a key. Every one of those is evidence for a milestone, and together
//! they are exactly what M5's exit criterion asks *not* to look like — "something a person
//! can play for five minutes without knowing it is a tech demo." The two requirements pull
//! against each other and both are worth keeping, so they are kept in two places.
//!
//! This one has no statistics, nothing to click, no debug keys and no stress test. It has a
//! hall with the lights out, six lamps, a door and a way out. What it is evidence *for* is
//! the claim M5's exit criterion is really making: **that Foundry can carry a game.** The
//! measure of that is not what this sample does, it is what the engine had to gain for it
//! to — which is nothing. Not one line of `engine/` changed to make this run.
//!
//! **Everything is content.** The map, the art, the sounds, the six lamp placements, the
//! walker's speed, the camera's zoom and every string on screen live in
//! `samples/room/content/`, and a package loaded after it changes any of them with nothing
//! rebuilt (I3, I5). The sample names ten content ids and no paths at all (ADR-0021).
//!
//! **Author coordinates.** Content places things by column and row of the map *as written*
//! — row 0 is the first row of `hall.grid`, the one at the top of the screen. The world is
//! Y-up with its origin in the middle of the map, and converting between the two is exactly
//! the arithmetic a person placing a lamp should never have to do. `Place.of` is where it
//! happens, once, and it is the only place in the sample that knows the map is upside down
//! relative to the file that draws it.
//!
//! **The autopilot is why the loop is checkable.** A sample whose completability can only
//! be established by a person holding a key is a sample nobody establishes anything about.
//! Set `FOUNDRY_ROOM_AUTOPILOT`, or run a headless build, and the walker goes and finds the
//! lamps itself — so "can this actually be finished" is a question a scripted run answers.

const std = @import("std");
const builtin = @import("builtin");

const app = @import("app");
const asset = @import("asset");
const audio = @import("audio");
const core = @import("core");
const data = @import("data");
const physics2d = @import("physics2d");
const platform = @import("platform");
const render2d = @import("render2d");
const rhi = @import("rhi");
const scene = @import("scene");

const log = core.log.scoped(.room);

/// What the room loads, **in load order**.
///
/// Package zero first (I3), then the sample's own — which is what a game ships. The engine
/// package supplies the font and nothing else; everything the room draws is the room's.
const content_packages = [_]app.ContentPackage{
    .{ .file = "core.fpk", .root = "core" },
    .{ .file = "room.fpk", .root = "room" },
};

/// The built-ins, plus whatever `FOUNDRY_ROOM_PACKAGES` names, in that order.
///
/// **This is the mod path with no mod manager in front of it** (CLAUDE.md §5). Compile a
/// package into `<prefix>/content`, name it here, and it overrides the room's content by
/// id — a different map, a seventh lamp, a translated sign — with nothing rebuilt but the
/// package. Discovering packages rather than being told about them is M7's job.
fn contentPackages(gpa: std.mem.Allocator, env: []const platform.os.EnvVar) ![]app.ContentPackage {
    var list: std.ArrayList(app.ContentPackage) = .empty;
    errdefer freePackages(gpa, list.items);
    errdefer list.deinit(gpa);

    for (content_packages) |pkg| try list.append(gpa, .{
        .file = try gpa.dupe(u8, pkg.file),
        .root = try gpa.dupe(u8, pkg.root),
    });

    const extra = for (env) |v| {
        if (std.mem.eql(u8, v.name, "FOUNDRY_ROOM_PACKAGES")) break v.value;
    } else return list.toOwnedSlice(gpa);

    var it = std.mem.splitScalar(u8, extra, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0) continue;
        // A location, not an identity, and therefore checked as one.
        if (!platform.os.isSafeRelativePath(name)) {
            log.warn("FOUNDRY_ROOM_PACKAGES: '{s}' is not a package name", .{name});
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

/// A headless build has no window and no way to deliver a quit event, so it bounds itself.
///
/// **A cap on the walk, not its length**: the run quits the moment the autopilot steps out
/// of the hall, and this is only how long it is allowed to take. Generous, because the
/// null platform's clock advances a millisecond a frame and the hall is a minute's walk —
/// a run that stopped halfway would prove the sample starts and nothing at all about
/// whether it can be finished, which is the one thing this run is for.
const default_headless_frames: u64 = 60000;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Zig 0.16 hands the environment to the entry point rather than exposing it ambiently,
    // and Foundry keeps it that way on purpose: configuration read from the air is a hidden
    // input (I9).
    const env = try app.environment(gpa, init);
    defer gpa.free(env);

    const headless = platform.backend == .null;

    const packages = try contentPackages(gpa, env);
    defer {
        freePackages(gpa, packages);
        gpa.free(packages);
    }

    var engine = try app.Engine.init(gpa, .{
        .env = env,
        .app_name = "foundry-room",
        .log_level = .info,
        .headless = headless,
        .tick_rate_hz = 60,
        .window = .{
            .title = "The Long Hall",
            .logical_width = 1280,
            .logical_height = 720,
            .surface = wanted_surface,
        },
        .content = packages,
    });
    defer engine.deinit();

    var room = try Room.init(gpa, engine.gpu);
    defer room.deinit(engine);
    try room.load(engine);

    // Nobody can hold a key in a headless run, so it drives itself. A windowed run can opt
    // in, which is what makes the scripted path and the played path the same path.
    room.autopilot = headless or engine.os.envVar("FOUNDRY_ROOM_AUTOPILOT") != null;

    const frame_limit = frameLimit(engine, headless);

    if (headless) {
        log.info("headless build ({t} backend): running {d} frames on autopilot", .{
            platform.backend, frame_limit.?,
        });
    } else {
        const info = engine.windowInfo().?;
        log.info("window: {d}x{d} points, {d}x{d} pixels, scale {d:.2}", .{
            info.logical_size.width, info.logical_size.height,
            info.pixel_size.width,   info.pixel_size.height,
            info.scale,
        });
        log.info("light every lamp in the hall. wasd or the arrows walk; escape quits", .{});
        if (room.autopilot) log.info("autopilot is on; the walker finds them itself", .{});
    }

    while (!engine.shouldQuit()) {
        engine.beginFrame();

        // Immediately after `beginFrame`, which is where a hot reload happens. Anything the
        // sample derived from content is derived again here, before the frame reads it.
        room.refresh(engine);

        // Drained so the window keeps answering; the room has no use for any of them.
        while (engine.nextEvent()) |_| {}

        while (engine.nextStep()) |step| {
            if (step.input.wasPressed(.escape)) engine.requestQuit();
            room.step(step);
        }

        // A finished headless run has nothing left to prove, and the frame cap is a bound
        // on how long the walk may take rather than how long it must.
        if (headless and room.finished) engine.requestQuit();

        room.present(engine);
        try room.submit(engine);

        engine.renderFrame(.{ .label = "room", .clear = room.clearColor() }, &room.renderer) catch |err| switch (err) {
            // No drawable this frame: minimised, occluded, or all of them still in flight.
            error.SurfaceLost => {},
            else => {
                log.err("frame {d} failed: {t}", .{ engine.frame_index, err });
                engine.requestQuit();
            },
        };

        engine.endFrame();

        // A windowed Metal build is paced by the display. The null backend has no swapchain
        // to wait on and would otherwise spin as fast as the CPU allows.
        if (!headless and rhi.backend == .null) engine.os.sleep(.fromMillis(2));

        if (frame_limit) |limit| {
            if (engine.frame_index >= limit) break;
        }
    }

    // What a scripted run has to say for itself. "Finished" is the only line here that
    // means the sample is completable; the rest is how far it got.
    const at = room.playerAt() orelse core.math.Vec2.zero;
    log.info("{s} at ({d:.0}, {d:.0}) after {d} frames, {d} ticks: {d} of {d} lamps lit, door {s}, {d} contact(s), {d} sound(s) started", .{
        if (room.finished) "finished" else "stopped",
        at.x,
        at.y,
        engine.frame_index,
        engine.stepper.tick,
        room.lit,
        room.lamps,
        if (room.doors.items.len == 0) "open" else "shut",
        room.contacts,
        room.sounds_played,
    });
}

/// Which surface kind the platform is asked for. macOS is the only one with a backend.
const wanted_surface: platform.SurfaceKind = switch (builtin.os.tag) {
    .macos => .metal_layer,
    else => .none,
};

/// A frame cap, from `FOUNDRY_ROOM_FRAMES`, or the headless default.
fn frameLimit(engine: *app.Engine, headless: bool) ?u64 {
    if (engine.os.envVar("FOUNDRY_ROOM_FRAMES")) |text| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, text, " "), 10) catch null) |value| {
            if (value > 0) return value;
        }
        log.warn("FOUNDRY_ROOM_FRAMES is not a positive number; ignoring it", .{});
    }
    return if (headless) default_headless_frames else null;
}

/// Everything the room is, read from content rather than written here.
const Settings = struct {
    sheet: core.ContentId,
    font: core.ContentId,
    map: core.ContentId,
    columns: u32,
    rows: u32,
    start_col: u32,
    start_row: u32,
    zoom: f32,
    player_size: f32,
    player_speed: f32,
    player_walk: core.ContentId,
    player_idle: core.ContentId,
    step_sound: core.ContentId,
    bump_sound: core.ContentId,
    chime_sound: core.ContentId,
    open_sound: core.ContentId,
    hum_sound: core.ContentId,
    title: []const u8,
    hint: []const u8,
    won: []const u8,
    lamp_label: []const u8,

    const id = "room:settings.main";

    /// What the sample draws when its own package is missing or malformed.
    ///
    /// **Not a duplicate of the content, and deliberately unattractive.** Nothing here
    /// names an asset, so a run that falls back to it draws an empty hall and says why —
    /// which is a diagnosable failure rather than a sample that mysteriously looks wrong.
    const fallback: Settings = .{
        .sheet = .none,
        .font = .none,
        .map = .none,
        .columns = 4,
        .rows = 4,
        .start_col = 0,
        .start_row = 0,
        .zoom = 3,
        .player_size = 11,
        .player_speed = 74,
        .player_walk = .none,
        .player_idle = .none,
        .step_sound = .none,
        .bump_sound = .none,
        .chime_sound = .none,
        .open_sound = .none,
        .hum_sound = .none,
        .title = "",
        .hint = "",
        .won = "",
        .lamp_label = "lamps lit",
    };

    fn read(engine: *app.Engine) Settings {
        const record = engine.store.lookup(core.ContentId.fromString(id)) orelse {
            log.err("'{s}' is not in any loaded package; there is no room to walk", .{id});
            return fallback;
        };
        const start = cellField(record, "start", .{ 0, 0 });

        return .{
            .sheet = idField(record, "sheet"),
            .font = idField(record, "font"),
            .map = idField(record, "map"),
            .columns = @max(intField(record, "columns", 4), 1),
            .rows = @max(intField(record, "rows", 4), 1),
            .start_col = start[0],
            .start_row = start[1],
            .zoom = floatField(record, "zoom", fallback.zoom),
            .player_size = floatField(record, "player_size", fallback.player_size),
            .player_speed = floatField(record, "player_speed", fallback.player_speed),
            .player_walk = idField(record, "player_walk"),
            .player_idle = idField(record, "player_idle"),
            .step_sound = idField(record, "step_sound"),
            .bump_sound = idField(record, "bump_sound"),
            .chime_sound = idField(record, "chime_sound"),
            .open_sound = idField(record, "open_sound"),
            .hum_sound = idField(record, "hum_sound"),
            .title = stringField(record, "title", ""),
            .hint = stringField(record, "hint", ""),
            .won = stringField(record, "won", ""),
            .lamp_label = stringField(record, "lamp_label", fallback.lamp_label),
        };
    }

    fn intField(record: data.store.Record, name: []const u8, fallback_value: u32) u32 {
        const index = record.schema.fieldIndex(name) orelse return fallback_value;
        const value = (record.fields.intAt(index) catch null) orelse return fallback_value;
        if (value < 0 or value > std.math.maxInt(u32)) return fallback_value;
        return @intCast(value);
    }

    /// A finite, positive number, or the fallback. A length, a speed and a zoom are all
    /// three of those, and zero and NaN are none of them — content is untrusted, including
    /// our own, and this is the sample answering for it at the boundary (CLAUDE.md §7).
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

    /// A two-element `[u32]` — a column and a row, or a width and a height.
    ///
    /// A list shorter than two is content that means nothing rather than content that means
    /// zero, so the fallback is returned whole rather than half-filled.
    fn cellField(record: data.store.Record, name: []const u8, fallback_value: [2]u32) [2]u32 {
        const index = record.schema.fieldIndex(name) orelse return fallback_value;
        const list = (record.fields.listAt(index) catch null) orelse return fallback_value;
        if (list.len < 2) return fallback_value;
        var out = fallback_value;
        for (0..2) |i| {
            const value = (list.intAt(@intCast(i)) catch null) orelse return fallback_value;
            if (value < 0 or value > std.math.maxInt(u32)) return fallback_value;
            out[i] = @intCast(value);
        }
        return out;
    }
};

/// The one place that knows the map is upside down relative to the file that draws it.
///
/// Content places things by **column and row of the map as written**: row 0 is the first
/// row of `hall.grid`, which is the row at the top of the screen. The runtime grid is
/// Y-up with row 0 at the bottom — `asset.tilegrid` reverses once, at compile time, so the
/// map is not upside down on screen — and the world origin is the middle of the map,
/// because that is where this sample chose to put it.
///
/// Three coordinate conventions, and an author should meet exactly one of them. So the
/// conversion lives here, is used by everything that places anything, and is the only
/// arithmetic in the sample worth a test if the sample had one.
const Place = struct {
    /// The world-space centre of a span of cells whose **top-left** cell in the file is
    /// `(col, row)` and which covers `wide` by `tall` cells.
    fn of(map: *const Map, col: u32, row: u32, wide: u32, tall: u32) core.math.Vec2 {
        const w: f32 = @floatFromInt(@max(wide, 1));
        const h: f32 = @floatFromInt(@max(tall, 1));
        return .init(
            map.origin.x + (@as(f32, @floatFromInt(col)) + w / 2) * map.cell.x,
            // `height - row` is the top edge of the span counted from the bottom, and half
            // its height back down from there is its middle.
            map.origin.y + (@as(f32, @floatFromInt(map.height)) - @as(f32, @floatFromInt(row)) - h / 2) * map.cell.y,
        );
    }

    /// The world-space half-extents of a span of `wide` by `tall` cells.
    fn half(map: *const Map, wide: u32, tall: u32) core.math.Vec2 {
        return .init(
            @as(f32, @floatFromInt(@max(wide, 1))) * map.cell.x / 2,
            @as(f32, @floatFromInt(@max(tall, 1))) * map.cell.y / 2,
        );
    }
};

/// The map the room stands on: drawn by `render2d`, collided with by `physics2d`.
///
/// **The second sample to write this, and that is worth saying out loud.** Nothing in the
/// engine turns a `foundry:tilemap` into a drawable and a collider — `asset` reads the
/// records, the registry answers for the grid and the texture, and joining them is the
/// game's, by `tilemaps-and-collision.md` §11's design. That was a claim when one sample
/// had paid it. Two samples arriving at the same two hundred lines is the evidence that
/// every game will write them, which is an argument for the engine owning a
/// `render2d`-side helper that neither this sample nor that one should make on its own.
///
/// Every failure here is a log line and a smaller map, never a stopped frame.
const Map = struct {
    const Plane = struct {
        texture: asset.AssetHandle,
        grid: asset.AssetHandle,
        layer: render2d.TilemapLayer,
        /// The tileset's `solid` list, as the bitset `physics2d.Grid` wants. **Owned here,
        /// borrowed by the collision world**, which copies the descriptor and not the
        /// arrays — the rule that lets `physics2d` stay at L1 without learning what an
        /// asset is.
        solid: []u32,
        collision: physics2d.GridHandle,
    };

    planes: std.ArrayList(Plane) = .empty,
    width: u32 = 0,
    height: u32 = 0,
    origin: core.math.Vec2 = .zero,
    cell: core.math.Vec2 = .zero,

    fn center(self: *const Map) core.math.Vec2 {
        if (self.width == 0 or self.height == 0) return .zero;
        return .init(
            self.origin.x + @as(f32, @floatFromInt(self.width)) * self.cell.x / 2,
            self.origin.y + @as(f32, @floatFromInt(self.height)) * self.cell.y / 2,
        );
    }

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
            log.warn("no map '{f}' in any loaded package; there is nowhere to walk", .{id});
            return;
        };
        const map = asset.tilemap.readTilemap(record) catch |err| {
            log.warn("map '{f}' is not a map ({t})", .{ id, err });
            return;
        };
        const layers = asset.tilemap.layerIds(gpa, record) catch |err| {
            log.warn("map '{f}' layers could not be read ({t})", .{ id, err });
            return;
        };
        defer gpa.free(layers);

        self.width = map.width;
        self.height = map.height;
        self.cell = .init(map.cell_width, map.cell_height);
        // The middle of the map is the world origin. A property of this sample, not of
        // maps: `foundry:tilemap` says how big a map is and never where it sits.
        self.origin = .init(
            -@as(f32, @floatFromInt(map.width)) * self.cell.x / 2,
            -@as(f32, @floatFromInt(map.height)) * self.cell.y / 2,
        );

        for (layers) |layer_id| {
            const plane = self.readPlane(gpa, engine, renderer, physics, layer_id, map) orelse continue;
            self.planes.append(gpa, plane) catch {
                _ = physics.removeGrid(plane.collision);
                gpa.free(plane.solid);
                engine.assets.release(plane.texture);
                engine.assets.release(plane.grid);
                return;
            };
        }
        log.info("map '{f}': {d}x{d} cells of {d}x{d}, {d} layer(s)", .{
            id, map.width, map.height, self.cell.x, self.cell.y, self.planes.items.len,
        });
    }

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
            log.warn("layer '{f}' names tileset '{f}', which is not loaded", .{ layer_id, layer.tileset });
            return null;
        };
        const set = asset.tilemap.readTileset(set_record) catch |err| {
            log.warn("tileset '{f}' could not be read ({t})", .{ layer.tileset, err });
            return null;
        };

        const texture_asset = engine.assets.acquire(gpa, set.texture) catch |err| {
            log.warn("tileset texture '{f}' did not load ({t})", .{ set.texture, err });
            return null;
        };
        const grid_asset = engine.assets.acquire(gpa, layer.grid) catch |err| {
            log.warn("tile grid '{f}' did not load ({t})", .{ layer.grid, err });
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
            log.warn("tileset texture '{f}' is not a texture", .{set.texture});
            return null;
        };
        const grid_payload = engine.assets.payloadOf(grid_asset) orelse return null;
        const grid = asset.tilegrid.fromPayload(grid_payload);

        if (grid.width != map.width or grid.height != map.height) {
            log.warn("tile grid '{f}' is {d}x{d} but its map is {d}x{d}; skipping the layer", .{
                layer.grid, grid.width, grid.height, map.width, map.height,
            });
            return null;
        }

        // One `[]const u16`, borrowed twice, by two modules that cannot see each other.
        if (layer.collides) {
            solid = asset.tilemap.solidBitset(gpa, set_record) catch |err| {
                log.warn("tileset '{f}' solid list could not be read ({t})", .{ layer.tileset, err });
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
                log.warn("layer '{f}' could not be collided with ({t})", .{ layer_id, err });
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

    fn draw(self: *const Map, renderer: *render2d.Renderer) !void {
        for (self.planes.items) |plane| {
            renderer.drawTilemap(plane.layer) catch |err| switch (err) {
                error.InvalidTilemap, error.InvalidTexture => {},
                else => return err,
            };
        }
    }

    /// The grid leaves the collision world **before** its arrays are freed, because the
    /// world holds them by reference.
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

/// One animation clip, read out of a `room:clip` record.
///
/// A plain copy rather than a borrowed `Record`: a content reload frees the package bytes a
/// record reads from, and seven numbers is nothing to copy.
const Clip = struct {
    id: core.ContentId,
    columns: u32,
    rows: u32,
    first: u32,
    count: u32,
    hold: u32,
    loops: bool,

    fn duration(self: *const Clip) u64 {
        return @as(u64, self.hold) * @as(u64, self.count);
    }
};

/// Every clip the loaded packages define, resolved once per content generation.
///
/// Built by iterating the store rather than by naming the five the sample uses, so a
/// package that arrives later with a sixth resolves the moment something references it.
const Clips = struct {
    list: std.ArrayList(Clip) = .empty,

    /// A bare `clip` in a package named `room:content` is the schema `room:clip`.
    const schema_name = "room:clip";

    fn build(self: *Clips, gpa: std.mem.Allocator, engine: *app.Engine) void {
        self.list.clearRetainingCapacity();

        const schema_id = data.SchemaId.parse(schema_name) catch {
            log.err("'{s}' is not a valid schema id; nothing will animate", .{schema_name});
            return;
        };

        var it = engine.store.iterate(schema_id);
        while (it.next()) |record| {
            self.list.append(gpa, .{
                .id = record.id,
                .columns = @max(Settings.intField(record, "columns", 1), 1),
                .rows = @max(Settings.intField(record, "rows", 1), 1),
                .first = Settings.intField(record, "first", 0),
                .count = Settings.intField(record, "count", 1),
                .hold = Settings.intField(record, "hold", 6),
                .loops = Settings.boolField(record, "loops", true),
            }) catch |err| {
                log.warn("could not hold clip {f} ({t})", .{ record.id, err });
                return;
            };
        }
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

// -- what the room's entities are made of ------------------------------------------------
//
// **A game defines its own component types.** The engine owns none of these and will not
// until M7 chooses the mod-facing vocabulary (`tilemaps-and-collision.md` §11): a component
// name is a compatibility decision, and inventing the standard one before a game has said
// what belongs on it freezes a guess.

const Transform = struct {
    pub const component = "room:transform";
    x: f32 = 0,
    y: f32 = 0,
};

/// What a thing looks like. Width and height separately, because the door is two cells wide
/// and one tall and a single `size` would have made it square.
const Visual = struct {
    pub const component = "room:visual";
    width: f32 = 16,
    height: f32 = 16,
    cell: u32 = 0,
    tint: render2d.Color = .{},
    /// `render2d.Sprite.layer` is an `i16`; the content type list has `i32`, and narrowing
    /// at the draw call is cheaper than a type nobody else would want.
    layer: i32 = 0,
};

/// A box that collides, centred on the entity's transform.
///
/// It holds half-extents and **not** a `physics2d.BodyHandle`: a handle is runtime identity
/// that a save must never carry (I1), so what persists is the shape and the body is rebuilt
/// from it.
const Solid = struct {
    pub const component = "room:solid";
    half_x: f32 = 6,
    half_y: f32 = 6,
};

/// Where an entity is in a clip. All three fields are integers, which is the whole design
/// (`sprite-animation.md` §4): a float accumulator drifts, does not survive a save, and
/// makes "which frame at tick 700?" only nearly answerable.
const Animation = struct {
    pub const component = "room:animation";
    clip: core.ContentId = .none,
    elapsed_ticks: u32 = 0,
    frame: u32 = 0,
};

/// A lamp, and whether it is lit.
///
/// `source` is the record this was built from, and it is here so that a content reload can
/// rebuild every placement from content and still hand back the lamps that were already
/// lit. Progress is the player's; placement is content's; keeping them apart is what lets
/// somebody edit the level while walking around in it.
const Lamp = struct {
    pub const component = "room:lamp";
    source: core.ContentId = .none,
    dark: core.ContentId = .none,
    lit_clip: core.ContentId = .none,
    lit: bool = false,
};

/// The door. A marker with the one fact the sample needs about it.
const Doorway = struct {
    pub const component = "room:doorway";
    source: core.ContentId = .none,
};

/// Advances every animated entity by one tick and records which frame that lands on.
///
/// **A `scene` system, where walking could not be**: a system is handed the tick and the
/// delta and nothing else, precisely so a simulation cannot read a device
/// (`entity-storage.md` §7). Advancing a clip does not want to; driving a character does.
///
/// It reaches `render2d` for the arithmetic, and that is not a crossing: `frameAt` is four
/// integers in and one out, `scene` never sees it, and the *game* is what joins the two.
fn animationSystem(ctx: ?*anyopaque, world: *scene.World, tick: scene.Tick) void {
    _ = tick;
    const clips: *const Clips = @ptrCast(@alignCast(ctx orelse return));

    var it = world.queryOf(.{Animation});
    while (it.next()) |m| {
        const animation = m.get(Animation);
        // A clip that is not loaded holds its frame rather than resetting it: a package can
        // be edited between one tick and the next, and a lamp mid-glow should not blink.
        const clip = clips.find(animation.clip) orelse continue;

        const total = clip.duration();
        animation.elapsed_ticks = if (clip.loops and total > 0)
            @intCast((@as(u64, animation.elapsed_ticks) + 1) % total)
        else
            animation.elapsed_ticks +| 1;

        animation.frame = render2d.frameAt(animation.elapsed_ticks, clip.hold, clip.count, clip.loops);
    }
}

/// The room.
const Room = struct {
    gpa: std.mem.Allocator,
    renderer: render2d.Renderer,
    camera: render2d.Camera2D,
    settings: Settings,

    sheet_asset: asset.AssetHandle,
    font_asset: asset.AssetHandle,
    sheet: render2d.Region,
    font: render2d.BitmapFont,

    map: Map = .{},
    clips: Clips = .{},
    physics: physics2d.World = .empty,

    /// The world, and the schema registry it borrows.
    ///
    /// The registry is the sample's own rather than the engine's: hot reload builds a whole
    /// new content set with a whole new `data.Registry` and swaps it, so a world holding a
    /// pointer into the engine's would be holding a freed one.
    schemas: data.Registry,
    world: scene.World,
    transform: scene.ComponentType = .none,
    visual: scene.ComponentType = .none,
    solid: scene.ComponentType = .none,
    animation: scene.ComponentType = .none,
    lamp_type: scene.ComponentType = .none,
    doorway: scene.ComponentType = .none,

    player: ?scene.Entity = null,
    player_body: physics2d.BodyHandle = .none,
    /// Lamp trigger bodies, so a lamp can be found by walking into it rather than by
    /// measuring the distance to every one of them every tick. A trigger blocks nothing and
    /// reports overlap, which is exactly what a pickup is.
    lamp_bodies: std.ArrayList(physics2d.BodyHandle) = .empty,
    doors: std.ArrayList(Door) = .empty,

    lamps: u32 = 0,
    lit: u32 = 0,
    /// Where the way out is, in world space. Zero-sized when content names none.
    exit_at: core.math.Vec2 = .zero,
    exit_half: core.math.Vec2 = .zero,
    finished: bool = false,

    mixer: ?*audio.Mixer = null,
    /// The door's own note, panned by where the walker is standing relative to it. It stops
    /// when the door does, which is the sample's one piece of diegetic audio.
    hum: audio.VoiceHandle = .none,
    since_step: u64 = 0,
    sounds_played: u64 = 0,
    contacts: u64 = 0,

    autopilot: bool = false,
    /// How close the autopilot has ever got to what it is walking at, and how long since
    /// that improved. A walker that has stopped making progress is one wedged on a corner.
    best: f32 = std.math.floatMax(f32),
    stuck_ticks: u32 = 0,
    detour_ticks: u32 = 0,
    detour_sign: f32 = 1,
    /// What it was walking at last tick, so a change of mind can be noticed.
    auto_target: ?core.math.Vec2 = null,

    content_generation: u64 = 0,
    /// **Copies, not borrows.** These strings live in a package's bytes, which a reload
    /// frees; the sample outlives a reload by exactly as long as it takes `refresh` to
    /// notice.
    text: TextBuffers = .{},

    /// One door: the entity, and the body that makes it solid.
    const Door = struct {
        entity: scene.Entity,
        body: physics2d.BodyHandle,
    };

    const TextBuffers = struct {
        title: [128]u8 = undefined,
        title_len: usize = 0,
        hint: [128]u8 = undefined,
        hint_len: usize = 0,
        won: [256]u8 = undefined,
        won_len: usize = 0,
        label: [64]u8 = undefined,
        label_len: usize = 0,
    };

    const hud_margin: f32 = 16;
    const hud_padding: f32 = 10;

    /// Ticks between footfalls while walking. At 60 Hz this is a step every third of a
    /// second, which is a walk rather than a sprint.
    const step_interval: u64 = 20;

    /// How fast the camera closes on the walker, per second. Presentation, so it may read a
    /// wall-clock delta — which simulation may not (I9).
    const follow_rate: f32 = 9;

    /// Which layer lamp triggers are on, so the overlap query asks for them and nothing
    /// else. Plain integers rather than a registry of named layers, per `physics2d`.
    const lamp_layer: u32 = 1 << 1;

    fn init(gpa: std.mem.Allocator, device: *rhi.Device) !Room {
        var renderer = try render2d.Renderer.init(gpa, device, .{ .frames_in_flight = 2 });
        errdefer renderer.deinit();

        return .{
            .gpa = gpa,
            .renderer = renderer,
            .camera = .{ .viewport = .init(0, 0, 1280, 720) },
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
            // `World.init` needs the registry's final address and this struct is returned
            // by value, so both are built in `load`.
            .schemas = undefined,
            .world = undefined,
        };
    }

    /// Registers the two loaders, reads the settings record, and builds the room.
    ///
    /// **Separate from `init` because the loaders borrow `&self.renderer` and the mixer**,
    /// and a struct returned by value has not reached its final address yet.
    fn load(self: *Room, engine: *app.Engine) !void {
        const gpa = self.gpa;

        // The capability points up, the dependency points down (I6). `app` has neither
        // `render2d` nor `audio`, so both are handed up from the game.
        try engine.assets.registerLoader(gpa, render2d.textureLoader(&self.renderer));

        self.mixer = audio.Mixer.init(gpa, engine.platform, &engine.assets, .{}) catch |err| blk: {
            // A machine with no output device is a configuration, not a bug.
            log.warn("no audio device ({t}); the hall is silent", .{err});
            break :blk null;
        };
        if (self.mixer) |mixer| try engine.assets.registerLoader(gpa, mixer.soundLoader());

        self.readSettings(engine);
        self.sheet_asset = try engine.assets.acquire(gpa, self.settings.sheet);
        self.font_asset = try engine.assets.acquire(gpa, self.settings.font);
        self.deriveRegions(engine);

        self.map.build(gpa, engine, &self.renderer, &self.physics, self.settings.map);
        self.clips.build(gpa, engine);
        self.content_generation = engine.contentGeneration();

        self.schemas = .init(gpa, .default);
        self.world = .init(gpa, &self.schemas, .default);
        try self.registerTypes();

        try self.spawnPlayer();
        self.rebuildPlacements(engine);
        self.startHum();

        self.camera.zoom = self.settings.zoom;
        self.camera.center = self.playerAt() orelse self.map.center();
        self.clampToMap();
    }

    fn registerTypes(self: *Room) !void {
        self.transform = try self.world.registerComponent(scene.componentType(Transform));
        self.visual = try self.world.registerComponent(scene.componentType(Visual));
        self.solid = try self.world.registerComponent(scene.componentType(Solid));
        self.animation = try self.world.registerComponent(scene.componentType(Animation));
        self.lamp_type = try self.world.registerComponent(scene.componentType(Lamp));
        self.doorway = try self.world.registerComponent(scene.componentType(Doorway));

        _ = try self.world.registerSystem(.{
            .id = try data.contentId("room:system.animation"),
            .name = "room:system.animation",
            .update = animationSystem,
            .ctx = &self.clips,
        });
    }

    // -- content into a room --------------------------------------------------------------

    /// Destroys every lamp and door and builds them from content again, **keeping which
    /// lamps were lit**.
    ///
    /// Called at load and on every content reload. A reload is somebody editing the level
    /// while walking around in it, and the two things they expect are that the edit takes
    /// effect and that they do not start again — so placement comes from content and lit
    /// state is carried across by the record id that placed it.
    fn rebuildPlacements(self: *Room, engine: *app.Engine) void {
        var was_lit: std.ArrayList(core.ContentId) = .empty;
        defer was_lit.deinit(self.gpa);

        var lamps = self.world.queryOf(.{Lamp});
        while (lamps.next()) |m| {
            const lamp = m.get(Lamp);
            if (lamp.lit) was_lit.append(self.gpa, lamp.source) catch {};
        }

        self.clearPlacements();
        self.buildLamps(engine, was_lit.items);
        self.buildDoors(engine);
        self.readWayOut(engine);

        // Content may have removed the lamp that was holding the door shut.
        if (self.lamps > 0 and self.lit >= self.lamps) self.openDoors();
    }

    fn clearPlacements(self: *Room) void {
        for (self.lamp_bodies.items) |body| _ = self.physics.removeBody(self.gpa, body);
        self.lamp_bodies.clearRetainingCapacity();
        for (self.doors.items) |door| {
            _ = self.physics.removeBody(self.gpa, door.body);
            _ = self.world.destroy(door.entity);
        }
        self.doors.clearRetainingCapacity();

        var it = self.world.queryOf(.{Lamp});
        var doomed: std.ArrayList(scene.Entity) = .empty;
        defer doomed.deinit(self.gpa);
        while (it.next()) |m| doomed.append(self.gpa, m.entity) catch {};
        for (doomed.items) |entity| _ = self.world.destroy(entity);

        self.lamps = 0;
        self.lit = 0;
    }

    fn buildLamps(self: *Room, engine: *app.Engine, was_lit: []const core.ContentId) void {
        const schema_id = data.SchemaId.parse("room:lamp") catch return;

        // The store's iteration order is documented and stable, which is what makes a room
        // built twice from the same packages the same room (I9).
        var it = engine.store.iterate(schema_id);
        while (it.next()) |record| {
            const cell = Settings.cellField(record, "at", .{ 0, 0 });
            const radius = Settings.floatField(record, "radius", 11);
            const dark = Settings.idField(record, "dark");
            const lit_clip = Settings.idField(record, "lit");

            var lit = false;
            for (was_lit) |id| {
                if (id.eql(record.id)) lit = true;
            }

            const at = Place.of(&self.map, cell[0], cell[1], 1, 1);
            const entity = self.world.create() catch |err| {
                log.warn("could not place lamp {f} ({t})", .{ record.id, err });
                return;
            };

            var transform: Transform = .{ .x = at.x, .y = at.y };
            var visual: Visual = .{
                .width = self.map.cell.x,
                .height = self.map.cell.y,
                .cell = 0,
                .tint = .srgb8(255, 255, 255, 255),
                .layer = 0,
            };
            var lamp: Lamp = .{
                .source = record.id,
                .dark = dark,
                .lit_clip = lit_clip,
                .lit = lit,
            };
            var animation: Animation = .{ .clip = if (lit) lit_clip else dark };

            _ = self.world.addComponent(entity, self.transform, std.mem.asBytes(&transform)) catch {};
            _ = self.world.addComponent(entity, self.visual, std.mem.asBytes(&visual)) catch {};
            _ = self.world.addComponent(entity, self.lamp_type, std.mem.asBytes(&lamp)) catch {};
            _ = self.world.addComponent(entity, self.animation, std.mem.asBytes(&animation)) catch {};

            // A trigger, so it is found by walking into it and blocks nothing on the way.
            const body = self.physics.addBody(self.gpa, .{
                .shape = .{ .circle = radius },
                .position = at,
                .kind = .trigger,
                .layer = lamp_layer,
                // The entire coupling between `physics2d` and the rest of the engine.
                .user = entity.bits(),
            }) catch |err| {
                log.warn("lamp {f} could not be walked into ({t})", .{ record.id, err });
                continue;
            };
            self.lamp_bodies.append(self.gpa, body) catch {};

            self.lamps += 1;
            if (lit) self.lit += 1;
        }
        log.info("{d} lamp(s) in the hall, {d} already lit", .{ self.lamps, self.lit });
    }

    fn buildDoors(self: *Room, engine: *app.Engine) void {
        const schema_id = data.SchemaId.parse("room:door") catch return;

        var it = engine.store.iterate(schema_id);
        while (it.next()) |record| {
            const cell = Settings.cellField(record, "at", .{ 0, 0 });
            const span = Settings.cellField(record, "span", .{ 1, 1 });
            const clip = Settings.idField(record, "clip");

            const at = Place.of(&self.map, cell[0], cell[1], span[0], span[1]);
            const half = Place.half(&self.map, span[0], span[1]);

            const entity = self.world.create() catch continue;
            var transform: Transform = .{ .x = at.x, .y = at.y };
            var visual: Visual = .{
                .width = half.x * 2,
                .height = half.y * 2,
                .tint = .srgb8(255, 255, 255, 255),
                .layer = 1,
            };
            var body_shape: Solid = .{ .half_x = half.x, .half_y = half.y };
            var animation: Animation = .{ .clip = clip };
            var marker: Doorway = .{ .source = record.id };

            _ = self.world.addComponent(entity, self.transform, std.mem.asBytes(&transform)) catch {};
            _ = self.world.addComponent(entity, self.visual, std.mem.asBytes(&visual)) catch {};
            _ = self.world.addComponent(entity, self.solid, std.mem.asBytes(&body_shape)) catch {};
            _ = self.world.addComponent(entity, self.animation, std.mem.asBytes(&animation)) catch {};
            _ = self.world.addComponent(entity, self.doorway, std.mem.asBytes(&marker)) catch {};

            const body = self.physics.addBody(self.gpa, .{
                .shape = .{ .box = .init(half.x, half.y) },
                .position = at,
                .kind = .static,
                .user = entity.bits(),
            }) catch |err| {
                log.warn("door {f} could not be made solid ({t})", .{ record.id, err });
                _ = self.world.destroy(entity);
                continue;
            };
            self.doors.append(self.gpa, .{ .entity = entity, .body = body }) catch {};
        }
    }

    fn readWayOut(self: *Room, engine: *app.Engine) void {
        self.exit_half = .zero;
        const schema_id = data.SchemaId.parse("room:way_out") catch return;

        var it = engine.store.iterate(schema_id);
        // The first one. A second way out is content saying two things, and taking the
        // first is at least a rule somebody can predict.
        const record = it.next() orelse {
            log.warn("no way out in any loaded package; the hall cannot be finished", .{});
            return;
        };
        const cell = Settings.cellField(record, "at", .{ 0, 0 });
        const span = Settings.cellField(record, "span", .{ 1, 1 });
        self.exit_at = Place.of(&self.map, cell[0], cell[1], span[0], span[1]);
        self.exit_half = Place.half(&self.map, span[0], span[1]);
    }

    fn spawnPlayer(self: *Room) !void {
        const at = if (self.map.width > 0)
            Place.of(&self.map, self.settings.start_col, self.settings.start_row, 1, 1)
        else
            core.math.Vec2.zero;
        const half = self.settings.player_size / 2;

        var transform: Transform = .{ .x = at.x, .y = at.y };
        var visual: Visual = .{
            .width = self.map.cell.x,
            .height = self.map.cell.y,
            .tint = .srgb8(255, 255, 255, 255),
            .layer = 2,
        };
        var body_shape: Solid = .{ .half_x = half, .half_y = half };
        var animation: Animation = .{ .clip = self.settings.player_idle };

        const entity = try self.world.create();
        _ = try self.world.addComponent(entity, self.transform, std.mem.asBytes(&transform));
        _ = try self.world.addComponent(entity, self.visual, std.mem.asBytes(&visual));
        _ = try self.world.addComponent(entity, self.solid, std.mem.asBytes(&body_shape));
        _ = try self.world.addComponent(entity, self.animation, std.mem.asBytes(&animation));

        self.player_body = self.physics.addBody(self.gpa, .{
            .shape = .{ .box = .init(half, half) },
            .position = at,
            .kind = .movable,
            .user = entity.bits(),
        }) catch |err| {
            log.warn("the walker has no body ({t}); it will walk through walls", .{err});
            self.player = entity;
            return;
        };
        self.player = entity;
        self.settlePlayer();
    }

    /// Pushes the walker out of anything it is standing inside.
    ///
    /// Deliberately not part of moving: a body that *starts* overlapping is not something a
    /// sweep can fix, so "I am stuck in a wall" stays a state the game is told about rather
    /// than a teleport it never sees. The moment it matters is a content reload that turns
    /// the floor underfoot into a wall.
    fn settlePlayer(self: *Room) void {
        const entity = self.player orelse return;
        var hits: [4]physics2d.Hit = undefined;
        const result = (self.physics.resolveOverlaps(self.gpa, self.player_body, &hits) catch return) orelse return;
        self.writeBack(entity, result.position);
    }

    // -- the simulation -------------------------------------------------------------------

    fn step(self: *Room, s: app.Step) void {
        self.world.update(.{ .tick = s.tick, .delta = s.delta });
        self.walk(s);
        self.light();
        self.checkWayOut(s.tick);
    }

    /// Moves the walker, in the fixed step, against the map.
    ///
    /// **This is not a `scene` system, and it cannot be.** A system is handed the tick and
    /// the delta and nothing else, precisely so a simulation cannot read a device — and
    /// driving something is reading a device. So it is the game's code, running in the
    /// game's fixed step, reading the step's frozen input snapshot rather than the live one.
    fn walk(self: *Room, s: app.Step) void {
        const entity = self.player orelse return;

        var direction = if (self.autopilot) self.autoDirection() else blk: {
            const in = &s.input;
            var d: core.math.Vec2 = .zero;
            // World space, so `w` is **+y**.
            if (in.isHeld(.a) or in.isHeld(.left)) d.x -= 1;
            if (in.isHeld(.d) or in.isHeld(.right)) d.x += 1;
            if (in.isHeld(.w) or in.isHeld(.up)) d.y += 1;
            if (in.isHeld(.s) or in.isHeld(.down)) d.y -= 1;
            break :blk d;
        };

        // Which clip plays is the game's decision, made every tick from what the game
        // already knows: one comparison, no state machine, and nothing in the engine that
        // had to be told about walking.
        const standing = direction.eql(.zero);
        self.play(entity, if (standing) self.settings.player_idle else self.settings.player_walk);
        if (standing) {
            // Primed, so the first footfall after standing lands on the tick the walker
            // starts moving rather than a third of a second into it.
            self.since_step = step_interval;
            return;
        }

        // **The simulation may cause a sound and may never observe one** (`audio.md` §8).
        self.since_step += 1;
        if (self.since_step >= step_interval) {
            self.since_step = 0;
            self.emit(self.settings.step_sound, .{ .gain = 0.35 });
        }

        direction = direction.normalize();
        const motion = direction.scale(self.settings.player_speed * s.delta.toSecondsF32());
        var hits: [4]physics2d.Hit = undefined;
        const result = (self.physics.moveAndSlide(self.gpa, self.player_body, motion, &hits) catch |err| {
            log.warn("the walker could not move: {t}", .{err});
            return;
        }) orelse return;

        if (result.total_hits > 0) {
            self.contacts += result.total_hits;
            // Only on the tick the contact starts, or walking along a wall is a drum roll.
            if (self.since_step == 0 or self.contacts == result.total_hits) {
                self.emit(self.settings.bump_sound, .{ .gain = 0.4 });
            }
        }
        self.writeBack(entity, result.position);
    }

    /// Lights whatever the walker is standing in.
    ///
    /// The query asks the collision world rather than measuring the distance to every lamp,
    /// which is the difference between a game and a loop over an array: the broadphase
    /// already knows what is near, the lamp's reach is content, and adding a hundred lamps
    /// costs the same tick.
    fn light(self: *Room) void {
        if (self.player_body.isNone()) return;
        const at = self.physics.body(self.player_body) orelse return;
        const half = at.shape.halfExtents();

        var hits: [8]physics2d.QueryHit = undefined;
        const found = self.physics.overlapShape(
            self.gpa,
            .{ .box = .init(half.x, half.y) },
            at.position,
            lamp_layer,
            &hits,
        ) catch return;

        for (hits[0..found.count]) |hit| {
            if (hit.isGrid()) continue;
            const entity = scene.Entity.fromBits(hit.user);
            const raw = self.world.getComponent(entity, self.lamp_type) orelse continue;
            const lamp: *Lamp = @ptrCast(@alignCast(raw.ptr));
            if (lamp.lit) continue;

            lamp.lit = true;
            self.lit += 1;
            self.play(entity, lamp.lit_clip);
            self.emit(self.settings.chime_sound, .{ .gain = 0.5 });
            log.info("a lamp catches: {d} of {d}", .{ self.lit, self.lamps });

            if (self.lit >= self.lamps and self.lamps > 0) {
                self.emit(self.settings.open_sound, .{ .gain = 0.8 });
                self.openDoors();
            }
        }
    }

    /// Takes every door out of the world.
    ///
    /// **One call removes the sprite and the collider both**, and that is the whole reason
    /// the door is an entity rather than a tile. A tile is a number in a grid that two
    /// subsystems are reading, and changing one means telling both; an entity that stops
    /// existing stops being drawn and stops being solid by the same act.
    fn openDoors(self: *Room) void {
        if (self.doors.items.len == 0) return;
        for (self.doors.items) |door| {
            _ = self.physics.removeBody(self.gpa, door.body);
            _ = self.world.destroy(door.entity);
        }
        log.info("the way out is open", .{});
        self.doors.clearRetainingCapacity();

        // The hum was the door's. Stopping it is the sample's one piece of audio that means
        // something rather than decorating something.
        if (self.mixer) |mixer| {
            if (!self.hum.isNone()) mixer.stop(self.hum);
            self.hum = .none;
        }
    }

    fn checkWayOut(self: *Room, tick: u64) void {
        if (self.finished or self.exit_half.x <= 0) return;
        const at = self.playerAt() orelse return;
        if (@abs(at.x - self.exit_at.x) > self.exit_half.x) return;
        if (@abs(at.y - self.exit_at.y) > self.exit_half.y) return;
        self.finished = true;
        // In ticks, because that is the clock the walk was measured against. A hall that
        // takes forty seconds of simulated time is a hall somebody spent forty seconds in,
        // whatever the frame rate was while they did.
        log.info("the walker steps out of the hall, after {d} tick(s)", .{tick});
    }

    /// Where the autopilot is going: the nearest unlit lamp, then the way out.
    ///
    /// **A scripted check, not an opponent.** It has no path-finding and does not need any:
    /// `moveAndSlide` slides along whatever it meets, which gets around a pillar most of the
    /// time, and the rest of the time this notices it has stopped making progress and
    /// strafes for a while. That is enough to answer the only question being asked — can
    /// the hall actually be finished — and anything cleverer would be a game AI in a sample
    /// that is not about one.
    fn autoDirection(self: *Room) core.math.Vec2 {
        const at = self.playerAt() orelse return .zero;
        const target = self.autoTarget() orelse return .zero;

        // **A new target invalidates the progress measurement against the old one.** The
        // walker arrives at a lamp with `best` near zero; if that carried over to the next
        // thing it walks at, nothing could ever be an improvement and it would spend the
        // rest of the run believing itself wedged.
        const changed = if (self.auto_target) |previous|
            @abs(previous.x - target.x) > 0.5 or @abs(previous.y - target.y) > 0.5
        else
            true;
        if (changed) {
            self.best = std.math.floatMax(f32);
            self.stuck_ticks = 0;
            self.detour_ticks = 0;
        }
        self.auto_target = target;

        const to = target.sub(at);
        const distance = to.length();
        if (distance < 0.5) return .zero;

        // Progress, or the lack of it. Reset whenever the target changes, because the first
        // measurement against a new one is always an improvement.
        if (distance < self.best - 0.5) {
            self.best = distance;
            self.stuck_ticks = 0;
        } else {
            self.stuck_ticks += 1;
        }
        if (self.stuck_ticks > 45 and self.detour_ticks == 0) {
            self.detour_ticks = 40;
            self.detour_sign = -self.detour_sign;
            self.stuck_ticks = 0;
        }

        const direct = to.scale(1 / distance);
        if (self.detour_ticks > 0) {
            self.detour_ticks -= 1;
            // Perpendicular, which in two dimensions is the whole of "go around it".
            return .init(-direct.y * self.detour_sign, direct.x * self.detour_sign);
        }
        return direct;
    }

    fn autoTarget(self: *Room) ?core.math.Vec2 {
        const at = self.playerAt() orelse return null;

        var best_at: ?core.math.Vec2 = null;
        var best_distance: f32 = std.math.floatMax(f32);
        var it = self.world.queryOf(.{ Lamp, Transform });
        while (it.next()) |m| {
            if (m.get(Lamp).lit) continue;
            const transform = m.get(Transform);
            const to: core.math.Vec2 = .init(transform.x - at.x, transform.y - at.y);
            const distance = to.length();
            if (distance < best_distance) {
                best_distance = distance;
                best_at = .init(transform.x, transform.y);
            }
        }
        if (best_at) |found| return found;
        if (self.exit_half.x > 0) return self.exit_at;
        return null;
    }

    fn play(self: *Room, entity: scene.Entity, clip: core.ContentId) void {
        const found = self.world.getComponent(entity, self.animation) orelse return;
        const animation: *Animation = @ptrCast(@alignCast(found.ptr));
        // Only when it is a different clip: a walk that reset its elapsed count every tick
        // it was still walking would hold frame zero forever.
        if (animation.clip.eql(clip)) return;
        animation.clip = clip;
        animation.elapsed_ticks = 0;
        animation.frame = 0;
    }

    /// Copies a body's position onto its entity's transform. One direction only: the body
    /// is authoritative while it is being moved, and the transform is what drawing reads.
    fn writeBack(self: *Room, entity: scene.Entity, at: core.math.Vec2) void {
        const found = self.world.getComponent(entity, self.transform) orelse return;
        const transform: *Transform = @ptrCast(@alignCast(found.ptr));
        transform.x = at.x;
        transform.y = at.y;
    }

    fn playerAt(self: *Room) ?core.math.Vec2 {
        const entity = self.player orelse return null;
        const found = self.world.getComponent(entity, self.transform) orelse return null;
        const transform: *const Transform = @ptrCast(@alignCast(found.ptr));
        return .init(transform.x, transform.y);
    }

    // -- audio ------------------------------------------------------------------------------

    fn startHum(self: *Room) void {
        const mixer = self.mixer orelse return;
        if (self.settings.hum_sound.isNone()) return;
        if (self.doors.items.len == 0) return;

        self.hum = mixer.play(self.settings.hum_sound, .{ .looping = true, .gain = 0.3 }) catch |err| {
            log.warn("the door's note did not start ({t})", .{err});
            return;
        };
        self.sounds_played += 1;
    }

    /// Starts a one-shot, or does nothing.
    ///
    /// **A sound that could not play is not a failure**: `play` refusing when every voice is
    /// busy is the design working — the mixer steals nothing and the game decides.
    fn emit(self: *Room, id: core.ContentId, params: audio.PlayParams) void {
        // A headless build has a device that never runs, so a command queued here would sit
        // in the ring until it filled and every one after it was refused.
        if (platform.backend == .null) return;
        const mixer = self.mixer orelse return;
        if (id.isNone()) return;
        _ = mixer.play(id, params) catch |err| {
            log.debug("sound {f} did not play: {t}", .{ id, err });
            return;
        };
        self.sounds_played += 1;
    }

    // -- the frame ---------------------------------------------------------------------------

    /// Everything outside the fixed step: the camera, and the mixer's frame.
    ///
    /// **Not simulation, and that is structural.** Where a camera looks and where a sound is
    /// panned are both derived from where the walker is *drawn*; `update` is a once-per-frame
    /// call by definition; and nothing in a simulation may read a mixer at all — `scene`
    /// cannot see `audio`, so none of this could be a system even if someone wanted it to be.
    fn present(self: *Room, engine: *app.Engine) void {
        const info = engine.windowInfo();
        const width: f32 = if (info) |i| @floatFromInt(i.logical_size.width) else 1280;
        const height: f32 = if (info) |i| @floatFromInt(i.logical_size.height) else 720;
        self.camera.viewport = .init(0, 0, width, height);

        // Eased rather than snapped, because a camera pinned to a walker makes the room
        // look like it is sliding and the walker like it is standing still. Exponential, so
        // the rate is the same whatever the frame time.
        if (self.playerAt()) |at| {
            const dt = engine.frameDelta().toSecondsF32();
            const t = 1 - @exp(-follow_rate * dt);
            self.camera.center = .init(
                self.camera.center.x + (at.x - self.camera.center.x) * t,
                self.camera.center.y + (at.y - self.camera.center.y) * t,
            );
            self.clampToMap();
        }

        const mixer = self.mixer orelse return;
        // Retirements come back here and nowhere else. Skip it and voices never return to
        // the free list.
        mixer.update();

        if (self.hum.isNone() or !mixer.isPlaying(self.hum)) return;
        const at = self.playerAt() orelse return;
        // The door is north of everything, so walking left of it moves its note right.
        const span = @max(1.0, @as(f32, @floatFromInt(self.map.width)) * self.map.cell.x * 0.35);
        var door_x: f32 = self.exit_at.x;
        if (self.doors.items.len > 0) {
            if (self.world.getComponent(self.doors.items[0].entity, self.transform)) |raw| {
                const transform: *const Transform = @ptrCast(@alignCast(raw.ptr));
                door_x = transform.x;
            }
        }
        mixer.setPan(self.hum, (door_x - at.x) / span);
    }

    /// Keeps the view inside the map.
    ///
    /// **Without this the hall has a visible edge**, and a room you can see the outside of
    /// is a rectangle of tiles rather than a place. Every game with hand-built levels does
    /// this and it costs ten lines; it is here because leaving it out is the single most
    /// noticeable way a room stops looking like one.
    ///
    /// An axis where the map is *narrower* than the view has no slack to take up, so it is
    /// centred rather than clamped — otherwise the two bounds cross and the camera snaps
    /// between them.
    fn clampToMap(self: *Room) void {
        if (self.map.width == 0 or self.map.height == 0) return;
        if (!(self.camera.zoom > 0)) return;

        const view: core.math.Vec2 = .init(
            self.camera.viewport.w / (2 * self.camera.zoom),
            self.camera.viewport.h / (2 * self.camera.zoom),
        );
        const half: core.math.Vec2 = .init(
            @as(f32, @floatFromInt(self.map.width)) * self.map.cell.x / 2,
            @as(f32, @floatFromInt(self.map.height)) * self.map.cell.y / 2,
        );
        const middle = self.map.center();

        self.camera.center.x = if (view.x >= half.x)
            middle.x
        else
            std.math.clamp(self.camera.center.x, middle.x - half.x + view.x, middle.x + half.x - view.x);
        self.camera.center.y = if (view.y >= half.y)
            middle.y
        else
            std.math.clamp(self.camera.center.y, middle.y - half.y + view.y, middle.y + half.y - view.y);
    }

    /// How dark the hall is, which is a function of how much of it is lit.
    ///
    /// The one piece of feedback that reaches the whole screen. Six lamps is not enough
    /// light to see by, and a room that visibly warms as they catch is the difference
    /// between a counter going up and something happening.
    fn clearColor(self: *const Room) [4]f32 {
        const share: f32 = if (self.lamps == 0) 1 else @as(f32, @floatFromInt(self.lit)) / @as(f32, @floatFromInt(self.lamps));
        const cold: [3]f32 = .{ 0.012, 0.014, 0.024 };
        const warm: [3]f32 = .{ 0.075, 0.055, 0.038 };
        return .{
            cold[0] + (warm[0] - cold[0]) * share,
            cold[1] + (warm[1] - cold[1]) * share,
            cold[2] + (warm[2] - cold[2]) * share,
            1,
        };
    }

    fn submit(self: *Room, engine: *app.Engine) !void {
        const scale: f32 = if (engine.windowInfo()) |i| i.scale else 1;
        try self.renderer.begin(.{ .camera = self.camera, .pixel_scale = scale });

        // The ground, before anything standing on it.
        try self.map.draw(&self.renderer);

        var it = self.world.queryOf(.{ Transform, Visual });
        while (it.next()) |m| {
            const transform = m.get(Transform);
            const visual = m.get(Visual);
            const cell = self.cellOf(visual, self.animationOf(m.entity));
            try self.renderer.drawSprite(.{
                .texture = cell.texture,
                .position = .init(transform.x, transform.y),
                .size = .init(visual.width, visual.height),
                .uv = cell.uv,
                .tint = visual.tint,
                .layer = @intCast(visual.layer),
            });
        }

        try self.sign();
        try self.hud(engine);
    }

    /// Which piece of the sheet an entity is showing.
    ///
    /// **This is `sprite-animation.md` §6's join, and it is three lines.** The entity side
    /// knows a clip id and a frame number and has never heard of a texture; the renderer
    /// side turns a grid position into a region and has never heard of an entity; the game
    /// is where they meet.
    fn cellOf(self: *const Room, visual: *const Visual, animation: ?*const Animation) render2d.Region {
        if (animation) |current| {
            if (self.clips.find(current.clip)) |clip| {
                return self.sheet.cell(clip.columns, clip.rows, clip.first +| current.frame);
            }
        }
        return self.sheet.cell(self.settings.columns, self.settings.rows, visual.cell);
    }

    fn animationOf(self: *Room, entity: scene.Entity) ?*const Animation {
        const found = self.world.getComponent(entity, self.animation) orelse return null;
        return @ptrCast(@alignCast(found.ptr));
    }

    /// The hall's name, in **world** units, over the rug the walker starts on.
    ///
    /// World-space text is a sign on a wall: it scrolls and scales with the camera and is
    /// part of the room rather than part of the interface.
    fn sign(self: *Room) !void {
        if (self.text.title_len == 0) return;
        const text = self.text.title[0..self.text.title_len];
        const options: render2d.TextOptions = .{ .position = .zero, .scale = 0.5 };
        const size = render2d.measureText(self.font, text, options);
        const at = Place.of(&self.map, self.settings.start_col, self.settings.start_row, 1, 1);
        try self.renderer.drawText(self.font, text, .{
            .position = .init(at.x - size.x / 2, at.y + self.map.cell.y * 2.2),
            .scale = 0.5,
            .tint = .srgb8(150, 160, 190, 190),
            .layer = 4,
        });
    }

    /// The only interface the room has: how many lamps are lit, and what to do about it.
    ///
    /// Screen space, so it does not move when the camera does — and there is nothing else on
    /// it. A frame-time readout would be the first thing that told a person this was a tech
    /// demo, which is precisely what this sample is here not to be.
    fn hud(self: *Room, engine: *app.Engine) !void {
        const info = engine.windowInfo();
        const width: f32 = if (info) |i| @floatFromInt(i.logical_size.width) else 1280;
        const height: f32 = if (info) |i| @floatFromInt(i.logical_size.height) else 720;

        try self.renderer.setView(.screen);
        defer self.renderer.setView(.world) catch {};

        var buffer: [128]u8 = undefined;
        const counter = std.fmt.bufPrint(&buffer, "{d} of {d} {s}", .{
            self.lit, self.lamps, self.text.label[0..self.text.label_len],
        }) catch return;
        try self.panelled(counter, .init(hud_margin, hud_margin), 2, .srgb8(255, 214, 150, 235));

        if (self.text.hint_len > 0 and self.lit == 0) {
            const hint = self.text.hint[0..self.text.hint_len];
            const size = render2d.measureText(self.font, hint, .{ .position = .zero, .scale = 1.5 });
            try self.panelled(
                hint,
                .init((width - size.x) / 2, height - size.y - hud_margin - hud_padding * 2),
                1.5,
                .srgb8(150, 155, 175, 210),
            );
        }

        if (self.finished and self.text.won_len > 0) {
            const won = self.text.won[0..self.text.won_len];
            const options: render2d.TextOptions = .{ .position = .zero, .scale = 3, .line_spacing = 8 };
            const size = render2d.measureText(self.font, won, options);
            try self.panelled(
                won,
                .init((width - size.x) / 2, (height - size.y) / 2),
                3,
                .srgb8(255, 236, 200, 255),
            );
        }
    }

    /// Text on a panel, so it stays legible over whatever it lands on. Drawn from the same
    /// atlas as the glyphs, so the panel costs no draw call of its own.
    fn panelled(
        self: *Room,
        text: []const u8,
        at: core.math.Vec2,
        scale: f32,
        tint: render2d.Color,
    ) !void {
        const options: render2d.TextOptions = .{ .position = at, .scale = scale, .line_spacing = 8 };
        const size = render2d.measureText(self.font, text, options);
        // The renderer's own white patch. The panel keeps working when a mod replaces the
        // sheet with one that has no white cell, because it never came from the sheet.
        const blank = self.renderer.blankRegion();
        try self.renderer.drawSprite(.{
            .texture = blank.texture,
            .uv = blank.uv,
            .position = .init(at.x - hud_padding, at.y - hud_padding),
            .size = .init(size.x + hud_padding * 2, size.y + hud_padding * 2),
            .origin = .init(0, 0),
            .tint = .srgb8(0, 0, 0, 165),
            .layer = 0,
        });
        try self.renderer.drawText(self.font, text, .{
            .position = at,
            .scale = scale,
            .line_spacing = 8,
            .tint = tint,
            .layer = 1,
        });
    }

    // -- content reload -----------------------------------------------------------------------

    /// Rebuilds everything **derived** from content, if content has moved since last time.
    ///
    /// Called every frame, right after `beginFrame` — which is where a reload happens, so
    /// nothing gets to read a stale derivation. A handle follows a swap on its own; a
    /// `Region` cut from a texture and a string borrowed from a package's bytes do not, and
    /// this is the other half of that promise being kept by the caller.
    fn refresh(self: *Room, engine: *app.Engine) void {
        const generation = engine.contentGeneration();
        if (generation == self.content_generation) return;
        self.content_generation = generation;

        const previous = self.settings;
        self.readSettings(engine);
        self.reacquire(engine, &self.sheet_asset, previous.sheet, self.settings.sheet);
        self.reacquire(engine, &self.font_asset, previous.font, self.settings.font);
        self.deriveRegions(engine);

        self.map.build(self.gpa, engine, &self.renderer, &self.physics, self.settings.map);
        self.clips.build(self.gpa, engine);
        self.rebuildPlacements(engine);

        // The floor underfoot may now be a wall.
        self.settlePlayer();
        self.camera.zoom = self.settings.zoom;

        if (self.hum.isNone()) self.startHum();
        log.info("content reloaded: {d} of {d} lamps still lit", .{ self.lit, self.lamps });
    }

    fn readSettings(self: *Room, engine: *app.Engine) void {
        self.settings = Settings.read(engine);
        copyInto(&self.text.title, &self.text.title_len, self.settings.title);
        copyInto(&self.text.hint, &self.text.hint_len, self.settings.hint);
        copyInto(&self.text.won, &self.text.won_len, self.settings.won);
        copyInto(&self.text.label, &self.text.label_len, self.settings.lamp_label);
    }

    fn copyInto(buffer: []u8, length: *usize, text: []const u8) void {
        length.* = @min(text.len, buffer.len);
        @memcpy(buffer[0..length.*], text[0..length.*]);
    }

    fn deriveRegions(self: *Room, engine: *app.Engine) void {
        if (self.renderer.textureRegion(self.textureOf(engine, self.sheet_asset))) |region| {
            self.sheet = region;
        }
        if (self.renderer.textureRegion(self.textureOf(engine, self.font_asset))) |region| {
            self.font.glyphs = region;
        }
    }

    fn reacquire(
        self: *Room,
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

    /// The registry holds a loader's product as one opaque word and never looks inside; the
    /// module that put a `TextureHandle` there is the one that may take it back out.
    fn textureOf(self: *Room, engine: *app.Engine, handle: asset.AssetHandle) render2d.TextureHandle {
        _ = self;
        const payload = engine.assets.payloadOf(handle) orelse return .none;
        return payload.asHandle(render2d.TextureHandle);
    }

    /// Teardown, strictly in reverse.
    ///
    /// **The mixer is shut down before the registry is torn down and deinitialised after**,
    /// which is `audio.md`'s three-call teardown: the loader has to go before `deinit`, and
    /// the mixer's asset references have to come back before the loader goes.
    fn deinit(self: *Room, engine: *app.Engine) void {
        // Before the collision world, because a plane's grid is registered in it and the
        // arrays that grid borrows are the plane's to free.
        self.map.deinit(self.gpa, engine, &self.physics);
        self.doors.deinit(self.gpa);
        self.lamp_bodies.deinit(self.gpa);
        self.physics.deinit(self.gpa);
        // The animation system holds a pointer to this and stops running when the world
        // below goes; nothing between here and there ticks.
        self.clips.deinit(self.gpa);

        engine.assets.release(self.sheet_asset);
        engine.assets.release(self.font_asset);
        _ = engine.assets.unregisterLoader(self.gpa, asset.schemas.texture.id);
        // The same shape, with one extra step in the middle. `shutdown` closes the device
        // and hands back the asset reference every playing voice held; only then may the
        // loader go, or the registry would rightly report that the door's note is still
        // holding the sound it is unloading.
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
};
