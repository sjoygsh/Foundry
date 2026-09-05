//! A map from authored text to a body colliding with it.
//!
//! The seam no module can test on its own. `asset` holds the record types and the grid
//! format, `physics2d` holds the collision and has never heard of a content id, and neither
//! can see the other — `physics2d` is L1 on `core` alone. So the wiring between them is only
//! reachable from where a game stands, which is here (`tilemaps-and-collision.md` §11).
//!
//! What this proves end to end: a `.fgrid` written by the same code `fpack` will call, an
//! authored `.fdt` compiled and loaded, the grid acquired **by content id and never by
//! path** (ADR-0021), the tileset's `solid` list turned into the bitset `physics2d` wants,
//! and a body stopped by a tile that a file said was solid.
//!
//! And then the other half of §11's diagram: the same slice handed to `render2d`, checking
//! that the cell it *draws* at a world position is the cell `physics2d` *collides* with
//! there. Neither module can make that claim alone, because neither can see the other.

const std = @import("std");
const asset = @import("asset");
const core = @import("core");
const data = @import("data");
const physics2d = @import("physics2d");
const render2d = @import("render2d");
const platform = @import("platform");

const Allocator = std.mem.Allocator;
const testing = std.testing;

/// The stack a game stands on for maps: content, assets, and a collision world.
///
/// No renderer. That is the point of the placement decision this exercises — a consumer
/// that wants map data and not a GPU is not obliged to link one.
const Stack = struct {
    gpa: Allocator,
    os: *platform.os.Os,
    dir: []const u8,
    schemas: data.Registry,
    diags: data.Diagnostics,
    store: data.Store,
    /// One compiled package's bytes per entry, because **the store borrows them**: a
    /// second package written over the first's buffer would move the ground under a store
    /// that is still reading it.
    blobs: std.ArrayList([]u8) = .empty,
    assets: asset.Registry,
    world: physics2d.World = .empty,
    /// The solid bitset the world borrows. A game owns this for as long as it owns the map,
    /// because `physics2d` borrows a grid's arrays and never copies them.
    solid: []u32 = &.{},
    /// The grid that bitset belongs to, so replacing one takes the other out of the world
    /// first. A grid left behind is a slice into memory nobody owns.
    grid: physics2d.GridHandle = .none,

    fn init() !*Stack {
        const gpa = testing.allocator;

        const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-integration", .env = &.{} });
        errdefer os.deinit();

        const temp = try os.tempDirAlloc(gpa);
        defer gpa.free(temp);
        const dir = try platform.os.joinPath(gpa, &.{ temp, "foundry-tilemap-pipeline" });
        errdefer gpa.free(dir);

        const self = try gpa.create(Stack);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .os = os,
            .dir = dir,
            .schemas = .init(gpa, .default),
            .diags = .init(gpa, .default),
            .store = .init(gpa, .default),
            .assets = undefined,
        };
        self.assets = .init(gpa, os, &self.store, .{});

        // The three runtime registrations a game makes, every one of them a call a mod
        // could make too (I6): the asset record types, the tilemap record types, and the
        // loader that turns one of them into tiles.
        try asset.schemas.registerAll(gpa, &self.schemas);
        try asset.tilemap.registerAll(gpa, &self.schemas);
        try self.assets.registerLoader(gpa, asset.tilegridLoader());
        return self;
    }

    fn deinit(self: *Stack) void {
        self.world.deinit(self.gpa);
        self.gpa.free(self.solid);
        self.assets.deinit(self.gpa);
        self.store.deinit(self.gpa);
        self.schemas.deinit(self.gpa);
        self.diags.deinit(self.gpa);
        // After the store, which was reading them.
        for (self.blobs.items) |blob| self.gpa.free(blob);
        self.blobs.deinit(self.gpa);
        self.gpa.free(self.dir);
        self.os.deinit();
        self.gpa.destroy(self);
    }

    fn writeFile(self: *Stack, rel: []const u8, contents: []const u8) !void {
        const path = try platform.os.joinPath(self.gpa, &.{ self.dir, rel });
        defer self.gpa.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.os.createDirPath(parent);
        try self.os.writeFile(path, contents);
    }

    /// Writes a grid asset the way `fpack` will: through `asset.tilegrid.write`, so the
    /// bytes on disk are the bytes the format says and not a test's idea of them.
    fn writeGrid(self: *Stack, rel: []const u8, width: u32, height: u32, tiles: []const u16) !void {
        const bytes = try asset.tilegrid.write(self.gpa, width, height, tiles);
        defer self.gpa.free(bytes);
        try self.writeFile(rel, bytes);
    }

    fn loadPackage(self: *Stack, name: []const u8, source: []const u8) !void {
        var doc = try data.parser.parse(self.gpa, "content.fdt", source, .{
            .namespace = name[0..std.mem.indexOfScalar(u8, name, ':').?],
        }, &self.diags);
        defer doc.deinit(self.gpa);

        var pkg = try data.check.Package.init(self.gpa, name, 1, .default);
        defer pkg.deinit(self.gpa);
        try pkg.addDocument(self.gpa, &doc, &self.schemas, &self.diags);

        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(self.gpa);
        try data.fpk.write(self.gpa, &pkg, &self.schemas, &bytes);
        const blob = try bytes.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(blob);
        try self.blobs.append(self.gpa, blob);

        const handle = try self.store.add(self.gpa, name, blob, &self.schemas, &self.diags);
        try self.assets.mount(self.gpa, handle, self.dir);
    }

    /// The wiring §11 says the game does, written once here so the test can read as the
    /// thing it is testing: a layer's content becomes a grid in a collision world.
    fn addLayer(
        self: *Stack,
        layer_id: []const u8,
        map: asset.tilemap.Tilemap,
        origin: core.math.Vec2,
    ) !physics2d.GridHandle {
        const layer = try asset.tilemap.readLayer(self.store.lookup(.fromString(layer_id)).?);
        const set = self.store.lookup(layer.tileset).?;

        const solid = try asset.tilemap.solidBitset(self.gpa, set);
        // Out of the world before its arrays go, and in that order: the world holds them by
        // reference and would otherwise be left pointing at freed memory.
        _ = self.world.removeGrid(self.grid);
        self.gpa.free(self.solid);
        // Borrowed by the world, so it outlives this call by living on the stack struct.
        // A game owns these two arrays exactly as long as it owns the map.
        self.solid = solid;

        const handle = try self.assets.acquire(self.gpa, layer.grid);
        const grid = asset.tilegrid.fromPayload(self.assets.payloadOf(handle).?);

        self.grid = try self.world.addGrid(self.gpa, .{
            .origin = origin,
            .cell = .{ .x = map.cell_width, .y = map.cell_height },
            .width = grid.width,
            .height = grid.height,
            .tiles = grid.tiles,
            .solid = solid,
        });
        return self.grid;
    }
};

const content =
    \\# The grid's record, written out rather than derived. `fpack` mints exactly this from
    \\# the file's path, and an author may write it instead to give the id explicitly
    \\# (ADR-0021); derivation is the compiler's business and is tested there.
    \\foundry:tilegrid sandbox:grids.town.walls { source "grids/town/walls.fgrid" }
    \\
    \\foundry:tileset sandbox:tiles.overworld {
    \\    texture   sandbox:textures.overworld
    \\    tile      [ 16 16 ]
    \\    columns   16
    \\    solid     [ 1 ]
    \\}
    \\
    \\foundry:tilemap.layer sandbox:map.town.walls {
    \\    tileset   sandbox:tiles.overworld
    \\    grid      sandbox:grids.town.walls
    \\    order     1
    \\    collides  true
    \\}
    \\
    \\foundry:tilemap sandbox:map.town {
    \\    size    [ 4 4 ]
    \\    cell    [ 1 1 ]
    \\    layers  [ sandbox:map.town.walls ]
    \\}
;

test "a map goes from authored text to a body that cannot walk through a wall" {
    const stack = try Stack.init();
    defer stack.deinit();

    // A 4x4 map with a wall down its right-hand column. Row 0 is the bottom row.
    try stack.writeGrid("grids/town/walls.fgrid", 4, 4, &.{
        0, 0, 0, 1,
        0, 0, 0, 1,
        0, 0, 0, 1,
        0, 0, 0, 1,
    });
    try stack.loadPackage("sandbox:content", content);

    const map = try asset.tilemap.readTilemap(stack.store.lookup(.fromString("sandbox:map.town")).?);
    _ = try stack.addLayer("sandbox:map.town.walls", map, .zero);

    const mover = try stack.world.addBody(stack.gpa, .{
        .shape = .{ .box = .{ .x = 0.5, .y = 0.5 } },
        .position = .{ .x = 0.5, .y = 2.5 },
        .kind = .movable,
    });

    var hits: [4]physics2d.Hit = undefined;
    const result = (try stack.world.moveAndSlide(stack.gpa, mover, .{ .x = 5, .y = 0 }, &hits)).?;

    try testing.expectEqual(@as(u32, 1), result.total_hits);
    try testing.expect(hits[0].isGrid());
    try testing.expectEqual([2]u32{ 3, 2 }, hits[0].cell);
    // The wall's left face is at x = 3 and the body is 0.5 wide, so it stops at 2.5.
    try testing.expectApproxEqAbs(@as(f32, 2.5), result.position.x, 2 * physics2d.contact_skin);
}

test "a package loaded later changes which tiles are solid, and the map is untouched" {
    // §12's Tier 1 claim, checked rather than asserted in prose: making a wall walkable is
    // editing a `solid` list in a tileset record, and it needs no code, no new map and no
    // mod system. The map file, the grid asset and the layer record are all byte-identical
    // across the two halves of this test; the only difference is a record that arrives
    // later and wins by id (I2, I3).
    const stack = try Stack.init();
    defer stack.deinit();

    try stack.writeGrid("grids/town/walls.fgrid", 4, 4, &.{
        0, 0, 0, 1,
        0, 0, 0, 1,
        0, 0, 0, 1,
        0, 0, 0, 1,
    });
    try stack.loadPackage("sandbox:content", content);

    const map = try asset.tilemap.readTilemap(stack.store.lookup(.fromString("sandbox:map.town")).?);
    _ = try stack.addLayer("sandbox:map.town.walls", map, .zero);

    const mover = try stack.world.addBody(stack.gpa, .{
        .shape = .{ .box = .{ .x = 0.5, .y = 0.5 } },
        .position = .{ .x = 0.5, .y = 2.5 },
        .kind = .movable,
    });

    var hits: [4]physics2d.Hit = undefined;
    const blocked = (try stack.world.moveAndSlide(stack.gpa, mover, .{ .x = 5, .y = 0 }, &hits)).?;
    try testing.expectEqual(@as(u32, 1), blocked.total_hits);

    // The mod. It restates one record — the tileset — and says a tile id the map does not
    // contain is the solid one. Nothing else in either package is mentioned.
    try stack.loadPackage("mod:content",
        \\foundry:tileset sandbox:tiles.overworld {
        \\    texture   sandbox:textures.overworld
        \\    tile      [ 16 16 ]
        \\    columns   16
        \\    solid     [ 2 ]
        \\}
    );

    // The same layer id, read again: the game rebuilds its grid after a content change, and
    // this is that rebuild. The `[]const u16` handed to `addGrid` is the identical slice
    // from the identical asset.
    _ = try stack.addLayer("sandbox:map.town.walls", map, .zero);
    _ = try stack.world.setPosition(stack.gpa, mover, .{ .x = 0.5, .y = 2.5 });

    const free = (try stack.world.moveAndSlide(stack.gpa, mover, .{ .x = 5, .y = 0 }, &hits)).?;
    try testing.expectEqual(@as(u32, 0), free.total_hits);
    try testing.expectApproxEqAbs(@as(f32, 5.5), free.position.x, 2 * physics2d.contact_skin);
}

test "the grid is reached by content id, and its path is never asked for" {
    const stack = try Stack.init();
    defer stack.deinit();

    // The file is at `grids/town/walls.fgrid`, so the id it derives is
    // `sandbox:grids.town.walls` -- and the id is what everything downstream uses. There is
    // no call anywhere that takes the path (ADR-0021).
    try stack.writeGrid("grids/town/walls.fgrid", 2, 1, &.{ 0, 1 });
    try stack.loadPackage("sandbox:content",
        \\foundry:tilegrid sandbox:grids.town.walls { source "grids/town/walls.fgrid" }
    );

    const handle = try stack.assets.acquire(stack.gpa, .fromString("sandbox:grids.town.walls"));
    const grid = asset.tilegrid.fromPayload(stack.assets.payloadOf(handle).?);
    try testing.expectEqual(@as(u32, 2), grid.width);
    try testing.expectEqual(@as(u32, 1), grid.height);
    try testing.expectEqual(@as(?u16, 1), grid.tileAt(1, 0));

    // Acquired twice is one load, and released twice is one unload -- the reference
    // counting the registry already had, applying to a kind it had never heard of.
    const again = try stack.assets.acquire(stack.gpa, .fromString("sandbox:grids.town.walls"));
    try testing.expectEqual(@as(?u32, 2), stack.assets.refCount(handle));
    stack.assets.release(again);
    stack.assets.release(handle);
}

test "a grid file that is not a grid fails the load and says which kind of wrong it is" {
    const stack = try Stack.init();
    defer stack.deinit();

    try stack.writeFile("grids/broken.fgrid", "this is not a grid");
    try stack.loadPackage("sandbox:content",
        \\foundry:tilegrid sandbox:grids.broken { source "grids/broken.fgrid" }
    );

    try testing.expectError(
        error.InvalidAsset,
        stack.assets.acquire(stack.gpa, .fromString("sandbox:grids.broken")),
    );
}

test "the tiles drawn and the tiles collided with are the same tiles" {
    // §11's diagram, checked rather than believed: one `[]const u16`, two consumers that
    // have never heard of each other, and a claim that they agree about where cell (x, y)
    // is. A map drawn one cell away from where you collide with it is the bug this exists
    // to catch, and it is invisible in either module's own tests.
    const stack = try Stack.init();
    defer stack.deinit();

    try stack.writeGrid("grids/town/walls.fgrid", 4, 4, &.{
        0, 0, 0, 1,
        0, 0, 0, 1,
        0, 0, 0, 1,
        0, 0, 0, 1,
    });
    try stack.loadPackage("sandbox:content", content);

    const map = try asset.tilemap.readTilemap(stack.store.lookup(.fromString("sandbox:map.town")).?);

    // **Not at the origin**, and that is the point of the number. Where a map sits is the
    // game's decision — a `foundry:tilemap` never says — so the sandbox centres its own, and
    // an origin applied on one side of the diagram and not the other is a map you collide
    // with four cells away from where you see it. Zero would not catch that.
    const origin: core.math.Vec2 = .init(-2, -2);
    _ = try stack.addLayer("sandbox:map.town.walls", map, origin);

    // The other consumer, built from the same records the collision grid was. No device and
    // no GPU: `render2d.Tiles` is the pure half of drawing, and this is the half that
    // decides *where*.
    const layer = try asset.tilemap.readLayer(stack.store.lookup(.fromString("sandbox:map.town.walls")).?);
    const set = try asset.tilemap.readTileset(stack.store.lookup(layer.tileset).?);
    const grid = asset.tilegrid.fromPayload(stack.assets.payloadOf(try stack.assets.acquire(stack.gpa, layer.grid)).?);

    var tiles: render2d.Tiles = try .init(.{
        // A 16x16 sheet of 16-pixel tiles, which is what the tileset record says. Nothing
        // here loads an image: where a tile is drawn does not depend on what it looks like.
        .tiles = .whole(.none, .{ .width = set.columns * set.tile_width, .height = 16 * set.tile_height }),
        .tile_size = .{ .width = set.tile_width, .height = set.tile_height },
        .columns = set.columns,
        .map = grid.tiles,
        .width = grid.width,
        .height = grid.height,
        .origin = origin,
        .cell = .init(map.cell_width, map.cell_height),
        .layer = layer.order,
    }, .init(origin.x, origin.y, 4, 4));

    var drawn: u32 = 0;
    var solid_drawn: u32 = 0;
    while (tiles.next()) |sprite| {
        drawn += 1;
        // The centre of the quad the renderer just placed, asked of the collision world.
        const centre: core.math.Vec2 = .{
            .x = sprite.position.x + sprite.size.x / 2,
            .y = sprite.position.y + sprite.size.y / 2,
        };
        var hits: [4]physics2d.QueryHit = undefined;
        const found = try stack.world.overlapPoint(stack.gpa, centre, ~@as(u32, 0), &hits);

        // The tile the sprite is showing, read back from the same slice both sides hold.
        const cx: u32 = @intFromFloat(sprite.position.x - origin.x);
        const cy: u32 = @intFromFloat(sprite.position.y - origin.y);
        const solid = grid.tileAt(cx, cy).? == 1;

        if (solid) {
            solid_drawn += 1;
            try testing.expectEqual(@as(u32, 1), found.count);
            try testing.expect(hits[0].isGrid());
            // And it is *this* cell, not a neighbour. One cell of drift would still report
            // a hit; this is the assertion that says which.
            try testing.expectEqual([2]u32{ cx, cy }, hits[0].cell);
        } else {
            try testing.expectEqual(@as(u32, 0), found.count);
        }
    }

    // Every cell of a 4x4 map, and the whole of its right-hand column solid.
    try testing.expectEqual(@as(u32, 16), drawn);
    try testing.expectEqual(@as(u32, 4), solid_drawn);
}
